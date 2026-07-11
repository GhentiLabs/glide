use std::sync::Arc;

use tokio::runtime::Runtime;

use crate::{app::state::SharedState, audio::AudioRecorder};

use super::ffi;

pub(super) struct TapContext {
    pub(super) shared: SharedState,
    pub(super) runtime: Arc<Runtime>,
    pub(super) recorder: AudioRecorder,
    pub(super) pressed: bool,
    /// Whether the toggle key has started a recording (press once to start, again to stop).
    pub(super) toggled: bool,
    /// The event tap's mach port, set right after creation so the callback can re-enable it.
    pub(super) tap: ffi::CFMachPortRef,
}

impl TapContext {
    pub(super) fn new(shared: SharedState, runtime: Arc<Runtime>) -> Self {
        Self {
            shared,
            runtime,
            recorder: AudioRecorder::new(),
            pressed: false,
            toggled: false,
            tap: std::ptr::null_mut(),
        }
    }
}
