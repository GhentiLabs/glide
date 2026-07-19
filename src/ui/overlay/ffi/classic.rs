use std::sync::{Arc, Mutex};

use super::objc::*;

pub(in crate::ui::overlay) struct NotchPanelState {
    panel: *mut c_void,
    bar_layers: Vec<*mut c_void>,
    dot_layers: Vec<*mut c_void>,
    width: f64,
    height: f64,
    pub(in crate::ui::overlay) eq_bars: Vec<f32>,
    pub(in crate::ui::overlay) loading_tick: usize,
}

unsafe impl Send for NotchPanelState {}
unsafe impl Sync for NotchPanelState {}

pub(in crate::ui::overlay) fn create_notch_panel(
    bar_rgba: (f64, f64, f64, f64),
) -> Option<Arc<Mutex<NotchPanelState>>> {
    let screen = crate::platform::notch_screen()?;
    let notch_w = screen
        .notch
        .map(|(width, _)| width)
        .unwrap_or(NOTCH_WIDTH_FALLBACK as f64);
    let notch_h = NOTCH_HEIGHT;
    let bar_count = NOTCH_BAR_COUNT;

    unsafe {
        let msg_ptr: MsgSendPtr = std::mem::transmute(objc_msgSend as *const ());
        let msg_bool: MsgSendBool = std::mem::transmute(objc_msgSend as *const ());
        let msg_i64: MsgSendI64 = std::mem::transmute(objc_msgSend as *const ());
        let msg_u64: MsgSendU64 = std::mem::transmute(objc_msgSend as *const ());
        let msg_f64: MsgSendF64 = std::mem::transmute(objc_msgSend as *const ());
        let msg_init_rect: MsgSendRectBoolBool = std::mem::transmute(objc_msgSend as *const ());
        let msg_set_rect: MsgSendSetRect = std::mem::transmute(objc_msgSend as *const ());

        // The screen frame is in global coordinates; x/y must include its origin.
        let x = screen.x + (screen.width - notch_w) / 2.0;
        let y_final = screen.y + screen.height - notch_h;
        let y_hidden = screen.y + screen.height;

        let ns_panel_class = objc_getClass(c"NSPanel".as_ptr());
        let panel = objc_msgSend(ns_panel_class, sel_registerName(c"alloc".as_ptr()));
        let content_rect = NSRect {
            x,
            y: y_hidden,
            w: notch_w,
            h: notch_h,
        };
        let panel = msg_init_rect(
            panel,
            sel_registerName(c"initWithContentRect:styleMask:backing:defer:".as_ptr()),
            content_rect,
            128,
            2,
            false,
        );
        if panel.is_null() {
            return None;
        }

        let clear_color = objc_msgSend(
            objc_getClass(c"NSColor".as_ptr()),
            sel_registerName(c"clearColor".as_ptr()),
        );
        msg_ptr(
            panel,
            sel_registerName(c"setBackgroundColor:".as_ptr()),
            clear_color,
        );
        msg_bool(panel, sel_registerName(c"setOpaque:".as_ptr()), false);
        msg_bool(panel, sel_registerName(c"setHasShadow:".as_ptr()), false);
        msg_i64(panel, sel_registerName(c"setLevel:".as_ptr()), 1000);
        msg_bool(
            panel,
            sel_registerName(c"setIgnoresMouseEvents:".as_ptr()),
            true,
        );
        msg_u64(
            panel,
            sel_registerName(c"setCollectionBehavior:".as_ptr()),
            NSWINDOW_COLLECTION_BEHAVIOR_CAN_JOIN_ALL_SPACES
                | NSWINDOW_COLLECTION_BEHAVIOR_FULL_SCREEN_AUXILIARY,
        );
        msg_bool(
            panel,
            sel_registerName(c"setHidesOnDeactivate:".as_ptr()),
            false,
        );

        let ns_view_class = objc_getClass(c"NSView".as_ptr());
        let content_view = objc_msgSend(ns_view_class, sel_registerName(c"alloc".as_ptr()));
        let content_view = objc_msgSend(content_view, sel_registerName(c"init".as_ptr()));
        let view_rect = NSRect {
            x: 0.0,
            y: 0.0,
            w: notch_w,
            h: notch_h,
        };
        msg_set_rect(
            content_view,
            sel_registerName(c"setFrame:".as_ptr()),
            view_rect,
            false,
        );
        msg_bool(
            content_view,
            sel_registerName(c"setWantsLayer:".as_ptr()),
            true,
        );
        let layer = objc_msgSend(content_view, sel_registerName(c"layer".as_ptr()));

        let cg_black = objc_msgSend(
            objc_getClass(c"NSColor".as_ptr()),
            sel_registerName(c"blackColor".as_ptr()),
        );
        let cg_color = objc_msgSend(cg_black, sel_registerName(c"CGColor".as_ptr()));
        msg_ptr(
            layer,
            sel_registerName(c"setBackgroundColor:".as_ptr()),
            cg_color,
        );
        msg_f64(
            layer,
            sel_registerName(c"setCornerRadius:".as_ptr()),
            NOTCH_CORNER_RADIUS,
        );
        msg_u64(
            layer,
            sel_registerName(c"setMaskedCorners:".as_ptr()),
            1 | 2,
        );
        msg_ptr(
            panel,
            sel_registerName(c"setContentView:".as_ptr()),
            content_view,
        );
        objc_release(content_view);

        let total_bars_width =
            bar_count as f64 * NOTCH_BAR_WIDTH + (bar_count as f64 - 1.0) * NOTCH_BAR_GAP;
        let start_x = (notch_w - total_bars_width) / 2.0;

        let ca_layer_class = objc_getClass(c"CALayer".as_ptr());
        let bar_cg_color = {
            type MsgSendRGBA =
                unsafe extern "C" fn(*mut c_void, *mut c_void, f64, f64, f64, f64) -> *mut c_void;
            let msg_rgba: MsgSendRGBA = std::mem::transmute(objc_msgSend as *const ());
            let (br, bg, bb, ba) = bar_rgba;
            let ns_color = msg_rgba(
                objc_getClass(c"NSColor".as_ptr()),
                sel_registerName(c"colorWithRed:green:blue:alpha:".as_ptr()),
                br,
                bg,
                bb,
                ba,
            );
            objc_msgSend(ns_color, sel_registerName(c"CGColor".as_ptr()))
        };

        let mut bar_layers = Vec::with_capacity(bar_count);
        for i in 0..bar_count {
            let bar_layer = objc_msgSend(ca_layer_class, sel_registerName(c"new".as_ptr()));
            let bx = start_x + i as f64 * (NOTCH_BAR_WIDTH + NOTCH_BAR_GAP);
            let bar_rect = NSRect {
                x: bx,
                y: notch_h - NOTCH_BAR_TOP_INSET - 2.0,
                w: NOTCH_BAR_WIDTH,
                h: 2.0,
            };
            type MsgSendSetCGRect = unsafe extern "C" fn(*mut c_void, *mut c_void, NSRect);
            let msg_set_cg_rect: MsgSendSetCGRect = std::mem::transmute(objc_msgSend as *const ());
            msg_set_cg_rect(bar_layer, sel_registerName(c"setFrame:".as_ptr()), bar_rect);
            msg_ptr(
                bar_layer,
                sel_registerName(c"setBackgroundColor:".as_ptr()),
                bar_cg_color,
            );
            msg_ptr(layer, sel_registerName(c"addSublayer:".as_ptr()), bar_layer);
            objc_release(bar_layer);
            bar_layers.push(bar_layer);
        }

        let total_dots_width = NOTCH_DOT_COUNT as f64 * NOTCH_DOT_SIZE
            + (NOTCH_DOT_COUNT as f64 - 1.0) * NOTCH_DOT_GAP;
        let dot_start_x = (notch_w - total_dots_width) / 2.0;
        let dot_y = NOTCH_DOT_BOTTOM_INSET;

        let mut dot_layers = Vec::with_capacity(NOTCH_DOT_COUNT);
        for i in 0..NOTCH_DOT_COUNT {
            let dot_layer = objc_msgSend(ca_layer_class, sel_registerName(c"new".as_ptr()));
            let dx = dot_start_x + i as f64 * (NOTCH_DOT_SIZE + NOTCH_DOT_GAP);
            let dot_rect = NSRect {
                x: dx,
                y: dot_y,
                w: NOTCH_DOT_SIZE,
                h: NOTCH_DOT_SIZE,
            };
            type MsgSendSetCGRect = unsafe extern "C" fn(*mut c_void, *mut c_void, NSRect);
            let msg_set_cg_rect: MsgSendSetCGRect = std::mem::transmute(objc_msgSend as *const ());
            msg_set_cg_rect(dot_layer, sel_registerName(c"setFrame:".as_ptr()), dot_rect);
            msg_ptr(
                dot_layer,
                sel_registerName(c"setBackgroundColor:".as_ptr()),
                bar_cg_color,
            );
            msg_f64(
                dot_layer,
                sel_registerName(c"setCornerRadius:".as_ptr()),
                NOTCH_DOT_SIZE / 2.0,
            );
            msg_bool(dot_layer, sel_registerName(c"setHidden:".as_ptr()), true);
            msg_ptr(layer, sel_registerName(c"addSublayer:".as_ptr()), dot_layer);
            objc_release(dot_layer);
            dot_layers.push(dot_layer);
        }

        objc_msgSend(panel, sel_registerName(c"orderFrontRegardless".as_ptr()));

        let ns_anim = objc_getClass(c"NSAnimationContext".as_ptr());
        objc_msgSend(ns_anim, sel_registerName(c"beginGrouping".as_ptr()));
        let current_ctx = objc_msgSend(ns_anim, sel_registerName(c"currentContext".as_ptr()));
        msg_f64(current_ctx, sel_registerName(c"setDuration:".as_ptr()), 0.2);
        type MsgSend4F =
            unsafe extern "C" fn(*mut c_void, *mut c_void, f32, f32, f32, f32) -> *mut c_void;
        let msg_4f: MsgSend4F = std::mem::transmute(objc_msgSend as *const ());
        let timing = msg_4f(
            objc_getClass(c"CAMediaTimingFunction".as_ptr()),
            sel_registerName(c"functionWithControlPoints::::".as_ptr()),
            0.0,
            0.0,
            0.2,
            1.0,
        );
        msg_ptr(
            current_ctx,
            sel_registerName(c"setTimingFunction:".as_ptr()),
            timing,
        );
        let animator = objc_msgSend(panel, sel_registerName(c"animator".as_ptr()));
        let final_rect = NSRect {
            x,
            y: y_final,
            w: notch_w,
            h: notch_h,
        };
        msg_set_rect(
            animator,
            sel_registerName(c"setFrame:display:".as_ptr()),
            final_rect,
            true,
        );
        objc_msgSend(ns_anim, sel_registerName(c"endGrouping".as_ptr()));

        Some(Arc::new(Mutex::new(NotchPanelState {
            panel,
            bar_layers,
            dot_layers,
            width: notch_w,
            height: notch_h,
            eq_bars: vec![0.0; bar_count],
            loading_tick: 0,
        })))
    }
}

pub(in crate::ui::overlay) fn update_notch_bars(state: &mut NotchPanelState, new_bars: &[f32]) {
    let attack = 0.6f32;
    let decay = 0.12f32;
    for (old, &new) in state.eq_bars.iter_mut().zip(new_bars) {
        let factor = if new > *old { attack } else { decay };
        *old += (new - *old) * factor;
    }
    let max_h = NOTCH_BAR_MAX_HEIGHT.min(state.height - NOTCH_BAR_TOP_INSET - 2.0);

    unsafe {
        let ca_transaction = objc_getClass(c"CATransaction".as_ptr());
        objc_msgSend(ca_transaction, sel_registerName(c"begin".as_ptr()));
        let msg_bool: MsgSendBool = std::mem::transmute(objc_msgSend as *const ());
        msg_bool(
            ca_transaction,
            sel_registerName(c"setDisableActions:".as_ptr()),
            true,
        );
        state.loading_tick = 0;

        let total_bars_width = state.bar_layers.len() as f64 * NOTCH_BAR_WIDTH
            + (state.bar_layers.len() as f64 - 1.0) * NOTCH_BAR_GAP;
        let start_x = (state.width - total_bars_width) / 2.0;
        type MsgSendSetCGRect = unsafe extern "C" fn(*mut c_void, *mut c_void, NSRect);
        let msg_set_cg_rect: MsgSendSetCGRect = std::mem::transmute(objc_msgSend as *const ());

        for &dot_layer in &state.dot_layers {
            msg_bool(dot_layer, sel_registerName(c"setHidden:".as_ptr()), true);
        }
        for (i, &magnitude) in state.eq_bars.iter().enumerate() {
            if i >= state.bar_layers.len() {
                break;
            }
            let bar_h = (magnitude as f64 * max_h).max(2.0);
            let bx = start_x + i as f64 * (NOTCH_BAR_WIDTH + NOTCH_BAR_GAP);
            let by = state.height - NOTCH_BAR_TOP_INSET - bar_h;
            let rect = NSRect {
                x: bx,
                y: by,
                w: NOTCH_BAR_WIDTH,
                h: bar_h,
            };
            msg_bool(
                state.bar_layers[i],
                sel_registerName(c"setHidden:".as_ptr()),
                false,
            );
            msg_set_cg_rect(
                state.bar_layers[i],
                sel_registerName(c"setFrame:".as_ptr()),
                rect,
            );
        }
        objc_msgSend(ca_transaction, sel_registerName(c"commit".as_ptr()));
    }
}

pub(in crate::ui::overlay) fn update_notch_loading(state: &mut NotchPanelState) {
    unsafe {
        let ca_transaction = objc_getClass(c"CATransaction".as_ptr());
        objc_msgSend(ca_transaction, sel_registerName(c"begin".as_ptr()));
        let msg_bool: MsgSendBool = std::mem::transmute(objc_msgSend as *const ());
        let msg_f32: MsgSendF32 = std::mem::transmute(objc_msgSend as *const ());
        msg_bool(
            ca_transaction,
            sel_registerName(c"setDisableActions:".as_ptr()),
            true,
        );

        for &bar_layer in &state.bar_layers {
            msg_bool(bar_layer, sel_registerName(c"setHidden:".as_ptr()), true);
        }
        state.loading_tick = state.loading_tick.wrapping_add(1);
        for (i, &dot_layer) in state.dot_layers.iter().enumerate() {
            let phase = ((state.loading_tick as f32 + i as f32 * 10.0) % 30.0) / 30.0;
            let opacity = (phase * std::f32::consts::PI).sin().max(0.12);
            msg_bool(dot_layer, sel_registerName(c"setHidden:".as_ptr()), false);
            msg_f32(
                dot_layer,
                sel_registerName(c"setOpacity:".as_ptr()),
                opacity,
            );
        }
        objc_msgSend(ca_transaction, sel_registerName(c"commit".as_ptr()));
    }
}

pub(in crate::ui::overlay) fn close_notch_panel(state: &NotchPanelState) {
    unsafe {
        objc_msgSend(state.panel, sel_registerName(c"orderOut:".as_ptr()));
        objc_release(state.panel);
    }
}
