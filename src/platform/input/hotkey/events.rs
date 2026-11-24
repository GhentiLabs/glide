use super::{
    context::TapContext,
    ffi,
    keys::{is_trigger_keycode, modifier_is_pressed},
    recording::{handle_press, handle_release},
};

pub(super) fn event_mask() -> u64 {
    ffi::cg_event_mask_bit(ffi::kCGEventKeyDown)
        | ffi::cg_event_mask_bit(ffi::kCGEventKeyUp)
        | ffi::cg_event_mask_bit(ffi::kCGEventFlagsChanged)
}

pub(super) unsafe extern "C" fn event_tap_callback(
    _proxy: ffi::CGEventTapProxy,
    event_type: u32,
    event: ffi::CGEventRef,
    user_info: *mut std::ffi::c_void,
) -> ffi::CGEventRef {
    let ctx = unsafe { &mut *(user_info as *mut TapContext) };

    // macOS disables the tap if the callback is too slow (or on certain user
    // input); we must re-enable it here or the hotkey stays dead until relaunch.
    if event_type == ffi::kCGEventTapDisabledByTimeout
        || event_type == ffi::kCGEventTapDisabledByUserInput
    {
        if !ctx.tap.is_null() {
            unsafe { ffi::CGEventTapEnable(ctx.tap, true) };
            eprintln!("[glide] Event tap disabled by system (type {event_type:#x}); re-enabled.");
        }
        return event;
    }

    let keycode =
        unsafe { ffi::CGEventGetIntegerValueField(event, ffi::kCGKeyboardEventKeycode) } as u16;

    if record_hotkey_if_needed(ctx, event_type, event, keycode) {
        return event;
    }

    let config = ctx.shared.config();
    let hold_trigger = config.hotkey.trigger;
    let toggle_trigger = config.hotkey.toggle_trigger;

    let is_hold = hold_trigger.is_some_and(|t| is_trigger_keycode(t, keycode));
    let is_toggle = toggle_trigger.is_some_and(|t| is_trigger_keycode(t, keycode));

    match event_type {
        ffi::kCGEventKeyDown => handle_key_down(ctx, is_hold, is_toggle),
        ffi::kCGEventKeyUp => handle_key_up(ctx, is_hold),
        ffi::kCGEventFlagsChanged => {
            let event_flags = unsafe { ffi::CGEventGetFlags(event) };
            handle_flags_changed(ctx, keycode, event_flags, is_hold, is_toggle);
        }
        _ => {}
    }

    event
}

fn record_hotkey_if_needed(
    ctx: &mut TapContext,
    event_type: u32,
    event: ffi::CGEventRef,
    keycode: u16,
) -> bool {
    if !ctx.shared.is_hotkey_recording() {
        return false;
    }

    if event_type != ffi::kCGEventKeyDown && event_type != ffi::kCGEventFlagsChanged {
        return true;
    }

    if event_type == ffi::kCGEventFlagsChanged && modifier_key_was_released(event, keycode) {
        return true;
    }

    ctx.shared.record_keycode(keycode);
    true
}

fn modifier_key_was_released(event: ffi::CGEventRef, keycode: u16) -> bool {
    let flags = unsafe { ffi::CGEventGetFlags(event) };
    let flag = crate::config::modifier_flag_for_keycode(keycode);
    flag != 0 && (flags & flag == 0)
}

fn handle_key_down(ctx: &mut TapContext, is_hold: bool, is_toggle: bool) {
    if is_hold && !ctx.pressed {
        handle_press(ctx);
    } else if is_toggle && !ctx.toggled {
        ctx.toggled = true;
        handle_press(ctx);
    } else if is_toggle && ctx.toggled {
        ctx.toggled = false;
        handle_release(ctx);
    }
}

fn handle_key_up(ctx: &mut TapContext, is_hold: bool) {
    if is_hold && ctx.pressed && !ctx.toggled {
        handle_release(ctx);
    }
}

fn handle_flags_changed(
    ctx: &mut TapContext,
    keycode: u16,
    event_flags: u64,
    is_hold: bool,
    is_toggle: bool,
) {
    let is_down = modifier_is_pressed(keycode, event_flags);

    if is_hold {
        if is_down && !ctx.pressed {
            handle_press(ctx);
        } else if !is_down && ctx.pressed && !ctx.toggled {
            handle_release(ctx);
        }
    }

    if is_toggle {
        if is_down && !ctx.toggled {
            ctx.toggled = true;
            handle_press(ctx);
        } else if is_down && ctx.toggled {
            ctx.toggled = false;
            handle_release(ctx);
        }
    }
}
