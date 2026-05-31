use serde::{Deserialize, Serialize};
use strum::EnumMessage as _;

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
pub enum OverlayStyle {
    #[strum(message = "Classic")]
    Classic,
    #[strum(message = "Glow")]
    Glow,
    #[strum(message = "None")]
    None,
}

impl OverlayStyle {
    pub fn label(self) -> &'static str {
        self.get_message().expect("overlay style label")
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
pub enum OverlayPosition {
    #[strum(message = "Notch")]
    Notch,
    #[strum(message = "Floating")]
    Floating,
}

impl OverlayPosition {
    pub fn label(self) -> &'static str {
        self.get_message().expect("overlay position label")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct OverlayConfig {
    pub style: OverlayStyle,
    pub width: u32,
    pub height: u32,
    pub position: OverlayPosition,
    pub opacity: f32,
}

impl Default for OverlayConfig {
    fn default() -> Self {
        Self {
            style: OverlayStyle::Classic,
            width: 300,
            height: 80,
            position: OverlayPosition::Floating,
            opacity: 0.85,
        }
    }
}
