//! Applies the user's theme preference and accent colour to the live UI.

use gpui::{App, Window};
use gpui_component::theme::{Theme, ThemeMode};

use crate::config::{ColorAccent, ThemePreference};

pub fn apply_theme_preference(
    pref: ThemePreference,
    accent: ColorAccent,
    window: Option<&mut Window>,
    cx: &mut App,
) {
    match pref {
        ThemePreference::System => Theme::sync_system_appearance(window, cx),
        ThemePreference::Light => Theme::change(ThemeMode::Light, window, cx),
        ThemePreference::Dark => Theme::change(ThemeMode::Dark, window, cx),
    }

    // Apply accent color overrides on top of the base light/dark theme
    let (h, s, l, a) = accent.primary_hsla();
    let (hh, sh, lh, ah) = accent.primary_hover_hsla();
    let (ha, sa, la, aa) = accent.primary_active_hsla();
    let theme = cx.global_mut::<Theme>();
    theme.colors.primary = gpui::hsla(h, s, l, a);
    theme.colors.primary_hover = gpui::hsla(hh, sh, lh, ah);
    theme.colors.primary_active = gpui::hsla(ha, sa, la, aa);
}
