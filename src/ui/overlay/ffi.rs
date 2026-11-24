#[cfg(target_os = "macos")]
mod classic;
#[cfg(target_os = "macos")]
mod glow;
#[cfg(target_os = "macos")]
mod objc;

#[cfg(target_os = "macos")]
pub(super) use classic::{
    NotchPanelState, close_notch_panel, create_notch_panel, update_notch_bars, update_notch_loading,
};
#[cfg(target_os = "macos")]
pub(super) use glow::{
    NotchGlowState, close_notch_glow_panel, create_notch_comet_panel, create_notch_glow_panel,
};
#[cfg(target_os = "macos")]
pub(super) use objc::NOTCH_BAR_COUNT;

#[cfg(not(target_os = "macos"))]
mod stubs {
    use std::sync::{Arc, Mutex};

    pub(super) const NOTCH_BAR_COUNT: usize = 16;

    pub(super) struct NotchPanelState;
    pub(super) struct NotchGlowState;

    pub(super) fn create_notch_panel(
        _bar_rgba: (f64, f64, f64, f64),
    ) -> Option<Arc<Mutex<NotchPanelState>>> {
        eprintln!("[glide] Notch overlay is not implemented on this platform.");
        None
    }

    pub(super) fn update_notch_bars(_state: &mut NotchPanelState, _new_bars: &[f32]) {}

    pub(super) fn update_notch_loading(_state: &mut NotchPanelState) {}

    pub(super) fn close_notch_panel(_state: &NotchPanelState) {}

    pub(super) fn create_notch_glow_panel(
        _glow_rgb: Option<(f64, f64, f64)>,
    ) -> Option<Arc<Mutex<NotchGlowState>>> {
        eprintln!("[glide] Glow notch overlay is not implemented on this platform.");
        None
    }

    pub(super) fn close_notch_glow_panel(_state: &NotchGlowState) {}
}

#[cfg(not(target_os = "macos"))]
pub(super) use stubs::{
    NOTCH_BAR_COUNT, NotchGlowState, NotchPanelState, close_notch_glow_panel, close_notch_panel,
    create_notch_glow_panel, create_notch_panel, update_notch_bars, update_notch_loading,
};
