use std::time::Instant;

use crate::{
    app::{
        state::{OverlayPhase, RuntimeStatus},
        trace::{TraceSession, attrs},
    },
    audio::RecordedAudio,
    engines::prewarm,
    pipeline,
    platform::permissions,
};

use super::context::TapContext;

pub(super) fn handle_press(ctx: &mut TapContext) {
    ctx.pressed = true;
    if matches!(ctx.shared.snapshot().status, RuntimeStatus::Processing) {
        return;
    }

    if !ensure_accessibility_ready(ctx) || !ensure_microphone_ready(ctx) {
        return;
    }

    start_recording(ctx);
}

fn ensure_accessibility_ready(ctx: &mut TapContext) -> bool {
    if permissions::has_accessibility_access()
        || permissions::request_accessibility_access_or_open_settings()
    {
        return true;
    }

    ctx.pressed = false;
    eprintln!(
        "[glide] Accessibility permission is required to paste dictated text. \
         Enable Glide in System Settings > Privacy & Security > Accessibility, then try again."
    );
    ctx.shared.set_error();
    dismiss_overlay(ctx);
    false
}

fn ensure_microphone_ready(ctx: &mut TapContext) -> bool {
    let microphone_status = permissions::microphone_authorization_status();

    if microphone_status == permissions::MicrophoneAuthorizationStatus::NotDetermined {
        handle_microphone_prompt(ctx);
        return false;
    }

    if !microphone_status.can_capture() {
        handle_microphone_unavailable(ctx, microphone_status);
        return false;
    }

    true
}

fn handle_microphone_prompt(ctx: &mut TapContext) {
    let requested_status = permissions::request_microphone_access();
    ctx.pressed = false;
    dismiss_overlay(ctx);

    if requested_status.can_capture() {
        ctx.shared.set_status(RuntimeStatus::Idle);
    } else if let Some(message) = permissions::microphone_access_error(requested_status) {
        eprintln!("[glide] {message}");
        ctx.shared.set_error();
        if requested_status.is_denied_or_restricted() {
            permissions::open_microphone_settings();
        }
    }
}

fn handle_microphone_unavailable(
    ctx: &mut TapContext,
    status: permissions::MicrophoneAuthorizationStatus,
) {
    ctx.pressed = false;
    if let Some(message) = permissions::microphone_access_error(status) {
        eprintln!("[glide] {message}");
    } else {
        eprintln!("[glide] Microphone access is not available");
    }
    ctx.shared.set_error();
    dismiss_overlay(ctx);
    if status.is_denied_or_restricted() {
        permissions::open_microphone_settings();
    }
}

fn start_recording(ctx: &mut TapContext) {
    // Detect frontmost app before recording starts (before overlay could steal focus)
    let frontmost = crate::platform::frontmost_app_name();
    ctx.shared.set_frontmost_app(frontmost.clone());
    prewarm::start_recording_prewarm(ctx.shared.clone(), ctx.runtime.clone(), frontmost.clone());

    let config = ctx.shared.config();
    match ctx.recorder.start(&config.audio) {
        Ok(live_audio) => {
            ctx.shared.set_live_audio(Some(live_audio));
            ctx.shared.set_status(RuntimeStatus::Recording);
            ctx.shared.set_overlay_phase(OverlayPhase::Recording);
        }
        Err(error) => {
            ctx.pressed = false;
            eprintln!("failed to start recording: {error:#}");
            ctx.shared.set_error();
        }
    }
}

pub(super) fn handle_release(ctx: &mut TapContext) {
    let release_started = Instant::now();
    let trace = TraceSession::from_env("dictation");
    trace.instant("hotkey_release");
    ctx.pressed = false;

    trace.measure("hotkey_release_overlay_processing", || {
        ctx.shared.set_overlay_phase(OverlayPhase::Processing)
    });
    trace.measure("hotkey_release_clear_live_audio", || {
        ctx.shared.set_live_audio(None)
    });

    let stop_started = Instant::now();
    let stop_result = if trace.is_enabled() {
        ctx.recorder.stop_profiled(&trace)
    } else {
        ctx.recorder.stop()
    };
    trace.record("hotkey_release_recorder_stop", stop_started.elapsed());

    match stop_result {
        Ok(audio) => {
            handle_recorded_audio(ctx, audio, trace, release_started);
        }
        Err(error) => {
            handle_stop_error(ctx, &trace, error);
        }
    }
}

fn handle_recorded_audio(
    ctx: &mut TapContext,
    audio: RecordedAudio,
    trace: TraceSession,
    release_started: Instant,
) {
    trace.instant_with_attrs(
        "hotkey_release_audio_ready",
        attrs([
            ("sample_count", audio.sample_count.to_string()),
            ("byte_count", audio.bytes.len().to_string()),
        ]),
    );
    trace.measure("hotkey_release_status_uploading", || {
        ctx.shared.set_status(RuntimeStatus::Processing)
    });

    let shared = ctx.shared.clone();
    let target_app = trace.measure("hotkey_release_frontmost_app_snapshot", || {
        shared.frontmost_app()
    });
    trace.record_since("hotkey_release_to_task_spawn", release_started);

    ctx.runtime.spawn(async move {
        trace.record_since("hotkey_release_to_task_start", release_started);
        match pipeline::process_recording(
            shared.clone(),
            audio,
            target_app,
            trace.clone(),
            Some(release_started),
        )
        .await
        {
            Ok(()) => {
                trace.measure("hotkey_release_overlay_dismiss_success", || {
                    shared.set_overlay_phase(OverlayPhase::Dismissed)
                });
            }
            Err(error) => {
                trace.instant_with_attrs("pipeline_error", attrs([("message", error.to_string())]));
                eprintln!("pipeline error: {error:#}");
                shared.set_error();
                trace.measure("hotkey_release_overlay_dismiss_error", || {
                    shared.set_overlay_phase(OverlayPhase::Dismissed)
                });
            }
        }
    });
}

fn handle_stop_error(ctx: &mut TapContext, trace: &TraceSession, error: anyhow::Error) {
    trace.instant_with_attrs(
        "hotkey_release_stop_error",
        attrs([("message", error.to_string())]),
    );
    eprintln!("recording stop error: {error:#}");
    ctx.shared.set_error();
    trace.measure("hotkey_release_overlay_dismiss_stop_error", || {
        dismiss_overlay(ctx)
    });
}

fn dismiss_overlay(ctx: &TapContext) {
    ctx.shared.set_overlay_phase(OverlayPhase::Dismissed);
}
