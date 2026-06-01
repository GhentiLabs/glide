use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::Result;

use crate::{audio, config::GlideConfig};

#[derive(Debug, Clone, Copy, PartialEq, Eq, strum::Display)]
pub enum RuntimeStatus {
    Starting,
    Idle,
    Recording,
    Processing,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, strum::FromRepr)]
#[repr(u8)]
pub enum OverlayPhase {
    Hidden = 0,
    Recording = 1,
    Processing = 2,
    Dismissed = 3,
}

pub struct LiveAudioData {
    pub ring: Vec<f32>,
    pub write_pos: usize,
    pub sample_rate: u32,
}

#[derive(Debug, Clone)]
pub struct AppSnapshot {
    pub config: GlideConfig,
    pub status: RuntimeStatus,
    pub input_devices: Vec<String>,
}

pub struct SharedAppState {
    inner: Mutex<AppState>,
    hotkey_recording: Mutex<HotkeyRecordingState>,
    /// Current overlay lifecycle phase (atomic for lock-free cross-thread access).
    overlay_phase: AtomicU8,
    /// Live audio ring buffer shared between the audio callback and overlay renderer.
    live_audio: Mutex<Option<Arc<Mutex<LiveAudioData>>>>,
    /// Name of the frontmost application when the hotkey was pressed.
    frontmost_app: Mutex<Option<String>>,
}

struct AppState {
    config: GlideConfig,
    status: RuntimeStatus,
    input_devices: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HotkeyRecordingState {
    Idle,
    Recording,
    Recorded(u16),
}

impl SharedAppState {
    pub fn new(config: GlideConfig) -> Self {
        Self {
            inner: Mutex::new(AppState {
                config,
                status: RuntimeStatus::Starting,
                input_devices: Vec::new(),
            }),
            hotkey_recording: Mutex::new(HotkeyRecordingState::Idle),
            overlay_phase: AtomicU8::new(OverlayPhase::Hidden as u8),
            live_audio: Mutex::new(None),
            frontmost_app: Mutex::new(None),
        }
    }

    pub fn snapshot(&self) -> AppSnapshot {
        let state = self.inner.lock().expect("state poisoned");
        AppSnapshot {
            config: state.config.clone(),
            status: state.status,
            input_devices: state.input_devices.clone(),
        }
    }

    pub fn config(&self) -> GlideConfig {
        self.inner.lock().expect("state poisoned").config.clone()
    }

    pub fn update_config(&self, update: impl FnOnce(&mut GlideConfig)) -> Result<()> {
        let mut state = self.inner.lock().expect("state poisoned");
        update(&mut state.config);
        state.config.save()?;
        Ok(())
    }

    pub fn refresh_input_devices(&self) {
        let devices = audio::list_input_devices().unwrap_or_else(|_| vec!["default".to_string()]);
        let mut state = self.inner.lock().expect("state poisoned");
        state.input_devices = if devices.is_empty() {
            vec!["default".to_string()]
        } else {
            devices
        };

        if state.config.audio.device != "default"
            && !state
                .input_devices
                .iter()
                .any(|device| device == &state.config.audio.device)
        {
            state.config.audio.device = "default".to_string();
            let _ = state.config.save();
        }
    }

    pub fn set_status(&self, status: RuntimeStatus) {
        let mut state = self.inner.lock().expect("state poisoned");
        state.status = status;
    }

    pub fn set_error(&self) {
        let mut state = self.inner.lock().expect("state poisoned");
        state.status = RuntimeStatus::Error;
    }

    /// Start hotkey recording - the CGEventTap will capture the next key press.
    pub fn start_hotkey_recording(&self) {
        *self
            .hotkey_recording
            .lock()
            .expect("hotkey_recording poisoned") = HotkeyRecordingState::Recording;
    }

    pub fn is_hotkey_recording(&self) -> bool {
        *self
            .hotkey_recording
            .lock()
            .expect("hotkey_recording poisoned")
            == HotkeyRecordingState::Recording
    }

    /// Called by the event tap when a key is pressed during recording.
    pub fn record_keycode(&self, code: u16) {
        *self
            .hotkey_recording
            .lock()
            .expect("hotkey_recording poisoned") = HotkeyRecordingState::Recorded(code);
    }

    /// Poll for a recorded keycode. Returns Some(code) once, then resets.
    pub fn poll_recorded_keycode(&self) -> Option<u16> {
        let mut state = self
            .hotkey_recording
            .lock()
            .expect("hotkey_recording poisoned");

        if let HotkeyRecordingState::Recorded(code) = *state {
            *state = HotkeyRecordingState::Idle;
            Some(code)
        } else {
            None
        }
    }

    pub fn set_overlay_phase(&self, phase: OverlayPhase) {
        self.overlay_phase.store(phase as u8, Ordering::SeqCst);
    }

    pub fn overlay_phase(&self) -> OverlayPhase {
        OverlayPhase::from_repr(self.overlay_phase.load(Ordering::SeqCst))
            .unwrap_or(OverlayPhase::Hidden)
    }

    pub fn set_frontmost_app(&self, app: Option<String>) {
        *self.frontmost_app.lock().expect("frontmost_app poisoned") = app;
    }

    pub fn frontmost_app(&self) -> Option<String> {
        self.frontmost_app
            .lock()
            .expect("frontmost_app poisoned")
            .clone()
    }

    pub fn set_live_audio(&self, data: Option<Arc<Mutex<LiveAudioData>>>) {
        *self.live_audio.lock().expect("live_audio poisoned") = data;
    }

    pub fn live_audio(&self) -> Option<Arc<Mutex<LiveAudioData>>> {
        self.live_audio.lock().expect("live_audio poisoned").clone()
    }
}

pub type SharedState = Arc<SharedAppState>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::GlideConfig;

    fn make_state() -> SharedAppState {
        SharedAppState::new(GlideConfig::default())
    }

    #[test]
    fn test_new_state_defaults() {
        let state = make_state();
        let snap = state.snapshot();
        assert_eq!(snap.status, RuntimeStatus::Starting);
    }

    #[test]
    fn test_set_status_updates_snapshot() {
        let state = make_state();
        state.set_status(RuntimeStatus::Idle);
        let snap = state.snapshot();
        assert_eq!(snap.status, RuntimeStatus::Idle);
    }

    #[test]
    fn test_set_error_updates_snapshot_status() {
        let state = make_state();
        state.set_error();
        assert_eq!(state.snapshot().status, RuntimeStatus::Error);
    }

    #[test]
    fn test_runtime_status_labels_are_exact() {
        let statuses = [
            (RuntimeStatus::Starting, "Starting"),
            (RuntimeStatus::Idle, "Idle"),
            (RuntimeStatus::Recording, "Recording"),
            (RuntimeStatus::Processing, "Processing"),
            (RuntimeStatus::Error, "Error"),
        ];
        for (status, label) in statuses {
            assert_eq!(status.to_string(), label);
        }
    }

    #[test]
    fn test_overlay_phase_transitions() {
        let state = make_state();
        assert_eq!(state.overlay_phase(), OverlayPhase::Hidden);

        state.set_overlay_phase(OverlayPhase::Recording);
        assert_eq!(state.overlay_phase(), OverlayPhase::Recording);

        state.set_overlay_phase(OverlayPhase::Processing);
        assert_eq!(state.overlay_phase(), OverlayPhase::Processing);

        state.set_overlay_phase(OverlayPhase::Dismissed);
        assert_eq!(state.overlay_phase(), OverlayPhase::Dismissed);

        state.set_overlay_phase(OverlayPhase::Hidden);
        assert_eq!(state.overlay_phase(), OverlayPhase::Hidden);
    }

    #[test]
    fn test_hotkey_recording_state_transitions() {
        let state = make_state();
        assert!(!state.is_hotkey_recording());
        assert_eq!(state.poll_recorded_keycode(), None);

        state.start_hotkey_recording();
        assert!(state.is_hotkey_recording());
        assert_eq!(state.poll_recorded_keycode(), None);

        state.record_keycode(0);
        assert!(!state.is_hotkey_recording());
        assert_eq!(state.poll_recorded_keycode(), Some(0));
        assert_eq!(state.poll_recorded_keycode(), None);
    }

    #[test]
    fn test_frontmost_app() {
        let state = make_state();
        assert!(state.frontmost_app().is_none());

        state.set_frontmost_app(Some("Safari".to_string()));
        assert_eq!(state.frontmost_app().as_deref(), Some("Safari"));

        state.set_frontmost_app(None);
        assert!(state.frontmost_app().is_none());
    }

    #[test]
    fn test_live_audio() {
        let state = make_state();
        assert!(state.live_audio().is_none());

        let data = Arc::new(Mutex::new(LiveAudioData {
            ring: vec![0.0; 8192],
            write_pos: 0,
            sample_rate: 16000,
        }));
        state.set_live_audio(Some(data.clone()));
        assert!(state.live_audio().is_some());

        state.set_live_audio(None);
        assert!(state.live_audio().is_none());
    }
}
