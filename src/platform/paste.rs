use std::{thread, time::Duration};

use anyhow::{Context, Result};
use arboard::Clipboard;
use objc2::rc::{Retained, autoreleasepool};
use objc2::runtime::ProtocolObject;
use objc2_app_kit::{NSPasteboard, NSPasteboardItem, NSPasteboardWriting};
use objc2_foundation::{NSArray, NSData, NSString};

use crate::config::PasteConfig;

const CLIPBOARD_SETTLE_DELAY_MS: u64 = 50;
const MIN_RESTORE_DELAY_MS: u64 = 750;

type CGEventRef = *mut std::ffi::c_void;
type CGEventSourceRef = *mut std::ffi::c_void;

const K_CG_HID_EVENT_TAP: u32 = 0;
const K_CG_EVENT_FLAG_MASK_COMMAND: u64 = 0x00100000;
const KVK_V: u16 = 9;

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGEventCreateKeyboardEvent(
        source: CGEventSourceRef,
        virtual_key: u16,
        key_down: bool,
    ) -> CGEventRef;
    fn CGEventSetFlags(event: CGEventRef, flags: u64);
    fn CGEventPost(tap: u32, event: CGEventRef);
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: *const std::ffi::c_void);
}

pub fn paste_text(text: &str, config: &PasteConfig) -> Result<()> {
    anyhow::ensure!(
        crate::platform::permissions::has_accessibility_access(),
        "Accessibility permission required for paste. Grant access in \
         System Settings > Privacy & Security > Accessibility and relaunch."
    );

    let previous_contents = previous_clipboard(config);

    let mut clipboard = Clipboard::new().context("failed to access clipboard")?;
    set_clipboard_text(&mut clipboard, text.to_string()).context("failed to update clipboard")?;
    let transcript_change_count = clipboard_change_count();

    thread::sleep(Duration::from_millis(CLIPBOARD_SETTLE_DELAY_MS));
    simulate_paste();

    if let Some(previous_contents) = previous_contents {
        restore_clipboard_async(
            previous_contents,
            text.to_string(),
            restore_delay(config),
            transcript_change_count,
        );
    }

    Ok(())
}

/// Full-fidelity snapshot of the general pasteboard: one entry per pasteboard
/// item, each holding every declared type (UTI) and its raw data.
struct ClipboardSnapshot {
    items: Vec<Vec<(String, Vec<u8>)>>,
}

fn previous_clipboard(config: &PasteConfig) -> Option<ClipboardSnapshot> {
    config.restore_clipboard.then(snapshot_clipboard).flatten()
}

fn clipboard_change_count() -> isize {
    autoreleasepool(|_| NSPasteboard::generalPasteboard().changeCount())
}

fn snapshot_clipboard() -> Option<ClipboardSnapshot> {
    // This runs on a background thread with no ambient autorelease pool.
    autoreleasepool(|_| {
        let pasteboard = NSPasteboard::generalPasteboard();
        let pasteboard_items = pasteboard.pasteboardItems()?;

        let mut items = Vec::with_capacity(pasteboard_items.len());
        for item in &pasteboard_items {
            // Reading data(forType:) resolves promised data; types whose data
            // comes back nil are skipped rather than failing the snapshot. The
            // inner pool drains the autoreleased NSData reads after each item.
            let representations: Vec<(String, Vec<u8>)> = autoreleasepool(|_| {
                item.types()
                    .iter()
                    .filter_map(|data_type| {
                        item.dataForType(&data_type)
                            .map(|data| (data_type.to_string(), data.to_vec()))
                    })
                    .collect()
            });
            if !representations.is_empty() {
                items.push(representations);
            }
        }

        (!items.is_empty()).then_some(ClipboardSnapshot { items })
    })
}

fn restore_clipboard(snapshot: ClipboardSnapshot, transcript: &str) -> Result<()> {
    autoreleasepool(|_| {
        // Stage every item fully before clearing the pasteboard so a staging
        // failure leaves the transcript in place instead of an empty clipboard.
        let mut staged: Vec<Retained<ProtocolObject<dyn NSPasteboardWriting>>> =
            Vec::with_capacity(snapshot.items.len());
        for representations in &snapshot.items {
            let item = NSPasteboardItem::new();
            for (data_type, bytes) in representations {
                let stored = item
                    .setData_forType(&NSData::with_bytes(bytes), &NSString::from_str(data_type));
                anyhow::ensure!(stored, "pasteboard item rejected data for type {data_type}");
            }
            staged.push(ProtocolObject::from_retained(item));
        }

        let pasteboard = NSPasteboard::generalPasteboard();
        pasteboard.clearContents();
        if !pasteboard.writeObjects(&NSArray::from_retained_slice(&staged)) {
            // The clear already emptied the pasteboard; put the transcript back
            // so paste output survives rather than leaving nothing behind.
            let transcript_restored = Clipboard::new()
                .and_then(|mut clipboard| clipboard.set_text(transcript.to_string()))
                .is_ok();
            if transcript_restored {
                anyhow::bail!("pasteboard rejected restored items; kept transcript text instead");
            }
            anyhow::bail!(
                "pasteboard rejected restored items and transcript re-write failed; clipboard left empty"
            );
        }
        Ok(())
    })
}

fn set_clipboard_text(clipboard: &mut Clipboard, text: String) -> Result<()> {
    clipboard.set_text(text).map_err(Into::into)
}

/// Simulate Cmd+V using CoreGraphics keyboard events.
fn simulate_paste() {
    unsafe {
        post_command_v_event(true);
        post_command_v_event(false);
    }
}

unsafe fn post_command_v_event(key_down: bool) {
    let event = unsafe { CGEventCreateKeyboardEvent(std::ptr::null_mut(), KVK_V, key_down) };
    unsafe {
        CGEventSetFlags(event, K_CG_EVENT_FLAG_MASK_COMMAND);
        CGEventPost(K_CG_HID_EVENT_TAP, event);
        CFRelease(event);
    }
}

fn restore_delay(config: &PasteConfig) -> Duration {
    Duration::from_millis(config.restore_delay_ms.max(MIN_RESTORE_DELAY_MS))
}

fn spawn_delayed_restore<F>(delay: Duration, restore: F) -> thread::JoinHandle<()>
where
    F: FnOnce() + Send + 'static,
{
    thread::spawn(move || {
        thread::sleep(delay);
        restore();
    })
}

fn restore_clipboard_async(
    previous_contents: ClipboardSnapshot,
    transcript: String,
    delay: Duration,
    transcript_change_count: isize,
) {
    spawn_delayed_restore(delay, move || {
        if clipboard_change_count() != transcript_change_count {
            tracing::info!("Paste: clipboard changed since paste; skipping restore");
            return;
        }
        match restore_clipboard(previous_contents, &transcript) {
            Ok(()) => tracing::info!("Paste: restored clipboard"),
            Err(error) => tracing::warn!("Paste: failed to restore clipboard: {error:#}"),
        }
    });
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;

    #[test]
    fn restore_delay_preserves_safe_values_and_clamps_unsafe_values() {
        let cases = [
            (1_000, Duration::from_millis(1_000)),
            (100, Duration::from_millis(MIN_RESTORE_DELAY_MS)),
        ];

        for (restore_delay_ms, expected) in cases {
            let config = PasteConfig {
                restore_clipboard: true,
                restore_delay_ms,
            };
            assert_eq!(restore_delay(&config), expected);
        }
    }

    #[test]
    fn delayed_restore_returns_without_waiting_for_delay() {
        let delay = Duration::from_millis(100);
        let started = Instant::now();
        let handle = spawn_delayed_restore(delay, || {});
        assert!(started.elapsed() < delay / 2);
        handle.join().unwrap();
    }

    /// End-to-end check that a multi-item, multi-type clipboard (text + HTML,
    /// PNG image, file URL) survives being overwritten by a transcript and
    /// then restored from a snapshot.
    #[test]
    #[ignore = "touches the live macOS pasteboard; run explicitly with --ignored"]
    fn snapshot_restore_round_trips_all_content_types() {
        let original = snapshot_clipboard();

        let staged = ClipboardSnapshot {
            items: vec![
                vec![
                    ("public.utf8-plain-text".to_string(), b"plain text".to_vec()),
                    ("public.html".to_string(), b"<b>rich text</b>".to_vec()),
                ],
                vec![(
                    "public.png".to_string(),
                    // Minimal valid PNG header bytes; content is irrelevant.
                    vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A],
                )],
                vec![(
                    "public.file-url".to_string(),
                    b"file:///private/tmp/glide-test.txt".to_vec(),
                )],
            ],
        };
        restore_clipboard(
            ClipboardSnapshot {
                items: staged.items.clone(),
            },
            "",
        )
        .expect("staging multi-type clipboard content should succeed");

        let snapshot = snapshot_clipboard().expect("snapshot should capture staged content");

        let mut clipboard = Clipboard::new().unwrap();
        set_clipboard_text(&mut clipboard, "transcript".to_string()).unwrap();

        restore_clipboard(
            ClipboardSnapshot {
                items: snapshot.items.clone(),
            },
            "transcript",
        )
        .expect("restore should succeed");

        let restored = snapshot_clipboard().expect("clipboard should have content after restore");

        // Every staged representation must survive the round trip verbatim.
        // (No strict snapshot equality: macOS may synthesize sibling UTI
        // representations, making the restored snapshot a superset.)
        for (item_index, staged_item) in staged.items.iter().enumerate() {
            for staged_representation in staged_item {
                assert!(
                    restored.items[item_index].contains(staged_representation),
                    "missing representation {:?} in restored item {item_index}",
                    staged_representation.0,
                );
            }
        }

        // Put back whatever was on the pasteboard before the test ran.
        if let Some(original) = original {
            let _ = restore_clipboard(original, "");
        }
    }
}
