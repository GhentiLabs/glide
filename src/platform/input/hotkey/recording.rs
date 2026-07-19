use crate::{
    app::state::{OverlayPhase, RuntimeStatus},
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
    tracing::warn!(
        "Accessibility permission is required to paste dictated text. \
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
        tracing::warn!("{message}");
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
        tracing::warn!("{message}");
    } else {
        tracing::warn!("Microphone access is not available");
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
            tracing::error!("failed to start recording: {error:#}");
            ctx.shared.set_error();
        }
    }
}

pub(super) fn handle_release(ctx: &mut TapContext) {
    ctx.pressed = false;

    ctx.shared.set_overlay_phase(OverlayPhase::Processing);
    ctx.shared.set_live_audio(None);

    match ctx.recorder.stop() {
        Ok(audio) => {
            handle_recorded_audio(ctx, audio);
        }
        Err(error) => {
            handle_stop_error(ctx, error);
        }
    }
}

fn handle_recorded_audio(ctx: &mut TapContext, audio: RecordedAudio) {
    ctx.shared.set_status(RuntimeStatus::Processing);

    let shared = ctx.shared.clone();
    let target_app = shared.frontmost_app();

    ctx.runtime.spawn(async move {
        match pipeline::process_recording(shared.clone(), audio, target_app).await {
            Ok(()) => {
                shared.set_overlay_phase(OverlayPhase::Dismissed);
            }
            Err(error) => {
                tracing::error!("pipeline error: {error:#}");
                shared.set_error();
                shared.set_overlay_phase(OverlayPhase::Dismissed);
            }
        }
    });
}

fn handle_stop_error(ctx: &mut TapContext, error: anyhow::Error) {
    tracing::error!("recording stop error: {error:#}");
    ctx.shared.set_error();
    dismiss_overlay(ctx);
}

fn dismiss_overlay(ctx: &TapContext) {
    ctx.shared.set_overlay_phase(OverlayPhase::Dismissed);
}
