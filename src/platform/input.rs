#[cfg(target_os = "macos")]
pub(crate) mod hotkey;

#[cfg(not(target_os = "macos"))]
pub(crate) mod hotkey {
    use std::sync::Arc;

    use tokio::runtime::Runtime;

    use crate::app::state::{RuntimeStatus, SharedState};

    pub fn start_listener(shared: SharedState, _runtime: Arc<Runtime>) {
        eprintln!("[glide] Global hotkeys are not implemented on this platform yet.");
        shared.set_status(RuntimeStatus::Idle);
    }
}
