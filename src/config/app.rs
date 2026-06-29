use serde::{Deserialize, Serialize};
use strum::EnumMessage as _;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AppConfig {
    pub launch_at_login: bool,
    pub menu_bar_icon: MenuBarIcon,
    pub theme: ThemePreference,
    pub accent: ColorAccent,
    #[serde(default)]
    pub onboarding_completed: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            launch_at_login: false,
            menu_bar_icon: MenuBarIcon::Default,
            theme: ThemePreference::System,
            accent: ColorAccent::Slate,
            onboarding_completed: false,
        }
    }
}

#[derive(
    Debug,
    Clone,
    Copy,
    Serialize,
    Deserialize,
    PartialEq,
    Eq,
    strum::EnumMessage,
    strum::VariantArray,
)]
#[serde(rename_all = "snake_case")]
pub enum ThemePreference {
    #[strum(message = "System")]
    System,
    #[strum(message = "Light")]
    Light,
    #[strum(message = "Dark")]
    Dark,
}

impl ThemePreference {
    pub fn label(self) -> &'static str {
        self.get_message().expect("theme label")
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MenuBarIcon {
    Default,
    Monochrome,
}

#[derive(
    Debug,
    Clone,
    Copy,
    Serialize,
    Deserialize,
    PartialEq,
    Eq,
    Default,
    strum::EnumMessage,
    strum::VariantArray,
)]
#[serde(rename_all = "snake_case")]
pub enum ColorAccent {
    #[strum(message = "Purple")]
    Purple,
    #[strum(message = "Blue")]
    Blue,
    #[strum(message = "Orange")]
    Orange,
    #[default]
    #[strum(message = "Slate")]
    Slate,
}

impl ColorAccent {
    pub fn label(self) -> &'static str {
        self.get_message().expect("accent label")
    }

    /// Primary accent color in HSLA for the GPUI theme system.
    pub fn primary_hsla(self) -> (f32, f32, f32, f32) {
        match self {
            // #7E6CC4 → hsl(252, 38%, 60%)
            Self::Purple => (0.70, 0.38, 0.60, 1.0),
            // #4A8FD4 → hsl(211, 58%, 56%)
            Self::Blue => (0.586, 0.58, 0.56, 1.0),
            // #F0603A → hsl(13, 85%, 58%)
            Self::Orange => (0.035, 0.85, 0.58, 1.0),
            // Near-black for dark selected pill appearance
            Self::Slate => (0.0, 0.0, 0.15, 1.0),
        }
    }

    /// Slightly lighter variant for hover state.
    pub fn primary_hover_hsla(self) -> (f32, f32, f32, f32) {
        let (h, s, l, a) = self.primary_hsla();
        (h, s, (l + 0.08).min(1.0), a)
    }

    /// Slightly darker variant for active/pressed state.
    pub fn primary_active_hsla(self) -> (f32, f32, f32, f32) {
        let (h, s, l, a) = self.primary_hsla();
        (h, s, (l - 0.08).max(0.0), a)
    }

    /// HSLA color for overlay EQ bars and loading dots.
    /// Slate uses the original neutral gray; others use tinted bars.
    pub fn bar_hsla(self) -> (f32, f32, f32, f32) {
        match self {
            // Original neutral gray bars
            Self::Slate => (0.0, 0.0, 0.78, 0.9),
            // Tinted bars matching the accent
            Self::Purple => (0.70, 0.35, 0.75, 0.9),
            Self::Blue => (0.586, 0.45, 0.75, 0.9),
            Self::Orange => (0.035, 0.65, 0.72, 0.9),
        }
    }

    /// RGBA color for notch overlay bars and dots (used in ObjC FFI).
    pub fn bar_rgba(self) -> (f64, f64, f64, f64) {
        match self {
            // Original neutral white bars
            Self::Slate => (0.78, 0.78, 0.78, 0.9),
            // Tinted bars matching the accent
            Self::Purple => (0.65, 0.55, 0.85, 0.9),
            Self::Blue => (0.45, 0.65, 0.88, 0.9),
            Self::Orange => (0.92, 0.50, 0.32, 0.9),
        }
    }

    /// Path to the app icon preview image for this accent.
    pub fn icon_asset(self) -> &'static str {
        match self {
            Self::Purple => "assets/icons/AppIcon-Purple.png",
            Self::Blue => "assets/icons/AppIcon-Blue.png",
            Self::Orange => "assets/icons/AppIcon-Orange.png",
            Self::Slate => "assets/icons/AppIcon-Slate.png",
        }
    }

    /// RGB values for the notch glow overlay effect.
    /// Returns `None` for Slate (rainbow hue-cycling glow).
    pub fn glow_rgb(self) -> Option<(f64, f64, f64)> {
        match self {
            Self::Purple => Some((0.36, 0.18, 0.80)),
            Self::Blue => Some((0.07, 0.39, 0.88)),
            Self::Orange => Some((0.97, 0.26, 0.05)),
            Self::Slate => None,
        }
    }
}
