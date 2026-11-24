//! Platform integration: system APIs, permission checks, paste simulation, and
//! global input (hotkey) handling.

pub mod input;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(not(target_os = "macos"))]
mod non_macos;
pub mod paste;
pub mod permissions;

#[cfg(target_os = "macos")]
pub use macos::{
    app_icon_path, frontmost_app_name, fuzzy_match, list_applications, main_display_size,
    notch_dimensions, notch_width, preload_app_icons,
};
#[cfg(not(target_os = "macos"))]
pub use non_macos::{
    app_icon_path, frontmost_app_name, fuzzy_match, list_applications, main_display_size,
    notch_dimensions, notch_width, preload_app_icons,
};
