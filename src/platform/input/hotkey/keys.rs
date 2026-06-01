use crate::config::{HotkeyTrigger, modifier_flag_for_keycode};

pub(super) mod keycode {
    pub(super) const OPTION_LEFT: u16 = 58;
    pub(super) const OPTION_RIGHT: u16 = 61;
    pub(super) const COMMAND_RIGHT: u16 = 54;
    pub(super) const F8: u16 = 100;
    pub(super) const F9: u16 = 101;
    pub(super) const F10: u16 = 109;
}

pub(super) fn is_trigger_keycode(trigger: HotkeyTrigger, keycode: u16) -> bool {
    match trigger {
        HotkeyTrigger::Option => {
            matches!(keycode, keycode::OPTION_LEFT | keycode::OPTION_RIGHT)
        }
        HotkeyTrigger::CommandRight => keycode == keycode::COMMAND_RIGHT,
        HotkeyTrigger::F8 => keycode == keycode::F8,
        HotkeyTrigger::F9 => keycode == keycode::F9,
        HotkeyTrigger::F10 => keycode == keycode::F10,
        HotkeyTrigger::Custom(code) => keycode == code,
    }
}

pub(super) fn modifier_is_pressed(keycode: u16, event_flags: u64) -> bool {
    let flag = modifier_flag_for_keycode(keycode);
    if flag == 0 {
        return false;
    }
    event_flags & flag != 0
}

#[cfg(test)]
mod tests {
    use super::*;

    // CGEvent flag masks used in tests.
    mod flags {
        pub const ALTERNATE: u64 = 0x00080000; // NSEventModifierFlagOption
        pub const COMMAND: u64 = 0x00100000; // NSEventModifierFlagCommand
    }

    #[test]
    fn trigger_keycodes_match_expected_keys() {
        let matching = [
            (HotkeyTrigger::Option, keycode::OPTION_LEFT),
            (HotkeyTrigger::Option, keycode::OPTION_RIGHT),
            (HotkeyTrigger::CommandRight, keycode::COMMAND_RIGHT),
            (HotkeyTrigger::F8, keycode::F8),
            (HotkeyTrigger::F9, keycode::F9),
            (HotkeyTrigger::F10, keycode::F10),
        ];
        for (trigger, keycode) in matching {
            assert!(
                is_trigger_keycode(trigger, keycode),
                "{trigger:?}/{keycode}"
            );
        }

        let non_matching = [
            (HotkeyTrigger::F8, keycode::F9),
            (HotkeyTrigger::Option, keycode::COMMAND_RIGHT),
            (HotkeyTrigger::CommandRight, keycode::OPTION_LEFT),
        ];
        for (trigger, keycode) in non_matching {
            assert!(
                !is_trigger_keycode(trigger, keycode),
                "{trigger:?}/{keycode}"
            );
        }
    }

    #[test]
    fn modifier_keycodes_match_expected_flags() {
        let matching = [
            (keycode::OPTION_LEFT, flags::ALTERNATE),
            (keycode::OPTION_RIGHT, flags::ALTERNATE),
            (keycode::COMMAND_RIGHT, flags::COMMAND),
            (55, flags::COMMAND),
            (56, 0x00020000),
            (60, 0x00020000),
            (59, 0x00040000),
            (62, 0x00040000),
        ];
        for (keycode, flags) in matching {
            assert!(modifier_is_pressed(keycode, flags), "{keycode}/{flags}");
        }

        let non_matching = [
            (keycode::OPTION_LEFT, 0),
            (keycode::OPTION_LEFT, flags::COMMAND),
            (keycode::COMMAND_RIGHT, 0),
            (keycode::F8, flags::ALTERNATE),
            (keycode::F9, flags::COMMAND),
            (0, 0xFFFFFFFF),
        ];
        for (keycode, flags) in non_matching {
            assert!(!modifier_is_pressed(keycode, flags), "{keycode}/{flags}");
        }
    }
}
