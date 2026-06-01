use std::fmt;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct HotkeyConfig {
    #[serde(default = "default_hold_trigger")]
    pub trigger: Option<HotkeyTrigger>,
    #[serde(default)]
    pub toggle_trigger: Option<HotkeyTrigger>,
}

impl Default for HotkeyConfig {
    fn default() -> Self {
        Self {
            trigger: default_hold_trigger(),
            toggle_trigger: None,
        }
    }
}

fn default_hold_trigger() -> Option<HotkeyTrigger> {
    Some(HotkeyTrigger::F8)
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HotkeyTrigger {
    Option,
    CommandRight,
    F8,
    F9,
    F10,
    Custom(u16),
}

impl HotkeyTrigger {
    pub fn label(self) -> String {
        match self {
            Self::Option => "⌥ Option".to_string(),
            Self::CommandRight => "⌘ Right Cmd".to_string(),
            Self::F8 => "F8".to_string(),
            Self::F9 => "F9".to_string(),
            Self::F10 => "F10".to_string(),
            Self::Custom(code) => keycode_label(code),
        }
    }

    pub fn from_keycode(code: u16) -> Self {
        match code {
            100 => Self::F8,
            101 => Self::F9,
            109 => Self::F10,
            _ => Self::Custom(code),
        }
    }
}

impl fmt::Display for HotkeyTrigger {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.label())
    }
}

fn keycode_label(code: u16) -> String {
    match code {
        0 => "A",
        1 => "S",
        2 => "D",
        3 => "F",
        4 => "H",
        5 => "G",
        6 => "Z",
        7 => "X",
        8 => "C",
        9 => "V",
        11 => "B",
        12 => "Q",
        13 => "W",
        14 => "E",
        15 => "R",
        16 => "Y",
        17 => "T",
        31 => "O",
        32 => "U",
        34 => "I",
        35 => "P",
        36 => "Return",
        37 => "L",
        38 => "J",
        40 => "K",
        45 => "N",
        46 => "M",
        49 => "Space",
        50 => "`",
        51 => "Delete",
        53 => "Escape",
        54 => "⌘ Right Cmd",
        55 => "⌘ Left Cmd",
        56 => "⇧ Left Shift",
        57 => "⇪ Caps Lock",
        58 => "⌥ Left Option",
        59 => "⌃ Left Ctrl",
        60 => "⇧ Right Shift",
        61 => "⌥ Right Option",
        62 => "⌃ Right Ctrl",
        63 => "Fn",
        96 => "F5",
        97 => "F6",
        98 => "F7",
        99 => "F3",
        100 => "F8",
        101 => "F9",
        103 => "F11",
        109 => "F10",
        111 => "F12",
        118 => "F4",
        120 => "F2",
        122 => "F1",
        _ => return format!("Key {code}"),
    }
    .to_string()
}

/// Return the CGEvent flag mask for a modifier keycode.
pub fn modifier_flag_for_keycode(code: u16) -> u64 {
    match code {
        54 | 55 => 0x00100000, // Command
        56 | 60 => 0x00020000, // Shift
        58 | 61 => 0x00080000, // Option
        59 | 62 => 0x00040000, // Control
        57 => 0x00010000,      // CapsLock
        63 => 0x00800000,      // Function
        _ => 0,
    }
}
