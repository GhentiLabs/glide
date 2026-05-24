mod classic;
mod glow;
mod objc;

pub(super) use classic::{
    NotchPanelState, close_notch_panel, create_notch_panel, update_notch_bars, update_notch_loading,
};
pub(super) use glow::{NotchGlowState, close_notch_glow_panel, create_notch_glow_panel};
pub(super) use objc::NOTCH_BAR_COUNT;
