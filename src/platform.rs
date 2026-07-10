//! macOS platform integration: system APIs, permission checks, paste
//! simulation, and global input (hotkey) handling.

pub mod input;
mod macos;
pub mod paste;
pub mod permissions;

pub use macos::{
    app_icon_path, frontmost_app_name, fuzzy_match, list_applications, main_display_size,
    notch_screen, notch_width, preload_app_icons,
};
