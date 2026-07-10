use std::ffi::{c_char, c_void};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use anyhow::{Context as _, Result};

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}
#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {}

unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> *mut c_void;
    fn sel_registerName(name: *const c_char) -> *mut c_void;
    fn objc_msgSend(receiver: *mut c_void, sel: *mut c_void) -> *mut c_void;
}

type MsgSendPtr = unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> *mut c_void;
type MsgSendUsize =
    unsafe extern "C" fn(*mut c_void, *mut c_void, usize, *mut c_void) -> *mut c_void;
type MsgSendLen = unsafe extern "C" fn(*mut c_void, *mut c_void) -> usize;
type MsgSendRect = unsafe extern "C" fn(*mut c_void, *mut c_void) -> NSRect;
type MsgSendObjAtIdx = unsafe extern "C" fn(*mut c_void, *mut c_void, usize) -> *mut c_void;

#[repr(C)]
#[derive(Copy, Clone)]
struct NSRect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

#[derive(Copy, Clone)]
struct NotchDimensions {
    width: f64,
    height: f64,
}

/// The screen the notch overlay should target: the display with a physical
/// notch, or the main screen when no notched display is attached.
///
/// The frame is in global (Cocoa) coordinates, so `x`/`y` are nonzero for any
/// screen that is not at the origin of the arrangement.
#[derive(Copy, Clone)]
pub struct NotchScreen {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// Physical notch (width, height); `None` on the notchless fallback.
    pub notch: Option<(f64, f64)>,
}

pub fn list_applications() -> Vec<String> {
    let mut apps: Vec<String> = std::fs::read_dir("/Applications")
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| application_name(&entry.path()))
        .collect();
    apps.sort_by_key(|app| app.to_lowercase());
    apps
}

fn application_name(path: &Path) -> Option<String> {
    path.extension()
        .is_some_and(|extension| extension == "app")
        .then(|| path.file_stem()?.to_str().map(str::to_string))
        .flatten()
}

static ICON_CACHE_DIR: OnceLock<PathBuf> = OnceLock::new();

fn icon_cache_dir() -> &'static Path {
    ICON_CACHE_DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join("glide-icons");
        let _ = fs::create_dir_all(&dir);
        dir
    })
}

pub fn app_icon_path(app_name: &str) -> Option<PathBuf> {
    existing_path(icon_cache_dir().join(format!("{app_name}.png")))
}

pub fn preload_app_icons() {
    std::thread::spawn(|| {
        let apps = list_applications();
        for app in &apps {
            let png_path = icon_cache_dir().join(format!("{app}.png"));
            if png_path.exists() {
                continue;
            }
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _ = extract_icon_to_png(app, &png_path);
            }));
        }
    });
}

fn existing_path(path: PathBuf) -> Option<PathBuf> {
    path.exists().then_some(path)
}

fn extract_icon_to_png(app_name: &str, dest: &Path) -> Result<()> {
    let msg1: MsgSendPtr = unsafe { std::mem::transmute(objc_msgSend as *const ()) };

    unsafe {
        let workspace = shared_workspace()?;

        let app_path = std::ffi::CString::new(format!("/Applications/{app_name}.app"))
            .context("invalid app name")?;
        let nsstring_class = objc_getClass(c"NSString".as_ptr());
        let ns_path = msg1(
            nsstring_class,
            sel_registerName(c"stringWithUTF8String:".as_ptr()),
            app_path.as_ptr() as *mut c_void,
        );
        if ns_path.is_null() {
            anyhow::bail!("failed to create NSString");
        }

        let icon = msg1(
            workspace,
            sel_registerName(c"iconForFile:".as_ptr()),
            ns_path,
        );
        if icon.is_null() {
            anyhow::bail!("failed to get icon");
        }

        write_nsimage_png(icon, dest)
    }
}

fn shared_workspace() -> Result<*mut c_void> {
    unsafe {
        let workspace_class = objc_getClass(c"NSWorkspace".as_ptr());
        if workspace_class.is_null() {
            anyhow::bail!("NSWorkspace class not found");
        }

        let workspace = objc_msgSend(
            workspace_class,
            sel_registerName(c"sharedWorkspace".as_ptr()),
        );
        if workspace.is_null() {
            anyhow::bail!("failed to get NSWorkspace");
        }

        Ok(workspace)
    }
}

fn write_nsimage_png(image: *mut c_void, dest: &Path) -> Result<()> {
    unsafe {
        let msg1: MsgSendPtr = std::mem::transmute(objc_msgSend as *const ());
        let msg_usize: MsgSendUsize = std::mem::transmute(objc_msgSend as *const ());
        let msg_len: MsgSendLen = std::mem::transmute(objc_msgSend as *const ());

        let tiff_data = objc_msgSend(image, sel_registerName(c"TIFFRepresentation".as_ptr()));
        if tiff_data.is_null() {
            anyhow::bail!("failed to get TIFF data");
        }

        let rep_class = objc_getClass(c"NSBitmapImageRep".as_ptr());
        if rep_class.is_null() {
            anyhow::bail!("NSBitmapImageRep class not found");
        }
        let rep = msg1(
            rep_class,
            sel_registerName(c"imageRepWithData:".as_ptr()),
            tiff_data,
        );
        if rep.is_null() {
            anyhow::bail!("failed to create bitmap rep");
        }

        let dict_class = objc_getClass(c"NSDictionary".as_ptr());
        let empty_dict = objc_msgSend(dict_class, sel_registerName(c"dictionary".as_ptr()));
        let png_data = msg_usize(
            rep,
            sel_registerName(c"representationUsingType:properties:".as_ptr()),
            4, // NSBitmapImageFileTypePNG
            empty_dict,
        );
        if png_data.is_null() {
            anyhow::bail!("failed to create PNG data");
        }

        let bytes_ptr = objc_msgSend(png_data, sel_registerName(c"bytes".as_ptr())) as *const u8;
        let length = msg_len(png_data, sel_registerName(c"length".as_ptr()));
        if bytes_ptr.is_null() || length == 0 {
            anyhow::bail!("empty PNG data");
        }

        let bytes = std::slice::from_raw_parts(bytes_ptr, length);
        fs::write(dest, bytes)
            .with_context(|| format!("failed to write icon to {}", dest.display()))?;

        Ok(())
    }
}

pub fn fuzzy_match(query: &str, candidate: &str) -> Option<i32> {
    if query.is_empty() {
        return Some(0);
    }
    let query_lower = query.to_lowercase();
    let candidate_lower = candidate.to_lowercase();
    let mut score = 0i32;
    let mut qi = query_lower.chars().peekable();
    for (i, c) in candidate_lower.chars().enumerate() {
        if qi.peek() == Some(&c) {
            qi.next();
            score += 100 - i as i32;
        }
    }
    if qi.peek().is_none() {
        Some(score)
    } else {
        None
    }
}

pub fn frontmost_app_name() -> Option<String> {
    let msg1: MsgSendPtr = unsafe { std::mem::transmute(objc_msgSend as *const ()) };

    unsafe {
        let workspace = shared_workspace().ok()?;

        let app = objc_msgSend(
            workspace,
            sel_registerName(c"frontmostApplication".as_ptr()),
        );
        if app.is_null() {
            return None;
        }

        let ns_name = objc_msgSend(app, sel_registerName(c"localizedName".as_ptr()));
        if ns_name.is_null() {
            return None;
        }

        let cstr_ptr = msg1(
            ns_name,
            sel_registerName(c"UTF8String".as_ptr()),
            std::ptr::null_mut(),
        ) as *const i8;
        if cstr_ptr.is_null() {
            return None;
        }

        let name = std::ffi::CStr::from_ptr(cstr_ptr)
            .to_string_lossy()
            .into_owned();
        Some(name)
    }
}

unsafe extern "C" {
    fn CGMainDisplayID() -> u32;
    fn CGDisplayPixelsWide(display: u32) -> usize;
    fn CGDisplayPixelsHigh(display: u32) -> usize;
}

pub fn main_display_size() -> (usize, usize) {
    unsafe {
        let display = CGMainDisplayID();
        (CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display))
    }
}

pub fn notch_width() -> Option<u32> {
    notch_screen()?.notch.map(|(width, _)| width as u32)
}

/// Finds the screen with a physical notch by scanning `[NSScreen screens]`,
/// falling back to `[NSScreen mainScreen]` (with `notch: None`) when none has
/// one. `mainScreen` follows the key window, so it must not be used to locate
/// the notch itself.
pub fn notch_screen() -> Option<NotchScreen> {
    unsafe {
        let ns_screen = objc_getClass(c"NSScreen".as_ptr());
        if ns_screen.is_null() {
            return None;
        }

        let msg_rect: MsgSendRect = std::mem::transmute(objc_msgSend as *const ());
        let msg_len: MsgSendLen = std::mem::transmute(objc_msgSend as *const ());
        let msg_at_idx: MsgSendObjAtIdx = std::mem::transmute(objc_msgSend as *const ());

        let screens = objc_msgSend(ns_screen, sel_registerName(c"screens".as_ptr()));
        if !screens.is_null() {
            let count = msg_len(screens, sel_registerName(c"count".as_ptr()));
            for i in 0..count {
                let screen = msg_at_idx(screens, sel_registerName(c"objectAtIndex:".as_ptr()), i);
                if screen.is_null() {
                    continue;
                }
                let frame = msg_rect(screen, sel_registerName(c"frame".as_ptr()));
                if let Some(notch) = notch_dimensions_of(screen, frame) {
                    return Some(NotchScreen {
                        x: frame.x,
                        y: frame.y,
                        width: frame.w,
                        height: frame.h,
                        notch: Some((notch.width, notch.height)),
                    });
                }
            }
        }

        let screen = objc_msgSend(ns_screen, sel_registerName(c"mainScreen".as_ptr()));
        if screen.is_null() {
            return None;
        }
        let frame = msg_rect(screen, sel_registerName(c"frame".as_ptr()));
        Some(NotchScreen {
            x: frame.x,
            y: frame.y,
            width: frame.w,
            height: frame.h,
            notch: None,
        })
    }
}

fn notch_dimensions_of(screen: *mut c_void, frame: NSRect) -> Option<NotchDimensions> {
    unsafe {
        let msg_rect: MsgSendRect = std::mem::transmute(objc_msgSend as *const ());

        let left_area = msg_rect(screen, sel_registerName(c"auxiliaryTopLeftArea".as_ptr()));
        let right_area = msg_rect(screen, sel_registerName(c"auxiliaryTopRightArea".as_ptr()));

        if left_area.w == 0.0 && right_area.w == 0.0 {
            return None;
        }

        let width = frame.w - left_area.w - right_area.w;
        let height = left_area.h;
        if width > 0.0 {
            Some(NotchDimensions { width, height })
        } else {
            None
        }
    }
}
