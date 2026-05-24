use std::sync::{Arc, Mutex};

use super::objc::*;

pub(in crate::overlay) struct NotchGlowState {
    panel: *mut c_void,
}

unsafe impl Send for NotchGlowState {}
unsafe impl Sync for NotchGlowState {}

pub(in crate::overlay) fn create_notch_glow_panel(
    glow_rgb: Option<(f64, f64, f64)>,
) -> Option<Arc<Mutex<NotchGlowState>>> {
    let (notch_w, notch_h) = crate::platform::notch_dimensions()
        .unwrap_or((NOTCH_WIDTH_FALLBACK as f64, NOTCH_HEIGHT_FALLBACK));
    let panel_w = notch_w + 2.0 * GLOW_PADDING;
    let panel_h = notch_h + GLOW_PADDING;
    let r = GLOW_CORNER_RADIUS;

    unsafe {
        let msg_ptr: MsgSendPtr = std::mem::transmute(objc_msgSend as *const ());
        let msg_bool: MsgSendBool = std::mem::transmute(objc_msgSend as *const ());
        let msg_i64: MsgSendI64 = std::mem::transmute(objc_msgSend as *const ());
        let msg_u64: MsgSendU64 = std::mem::transmute(objc_msgSend as *const ());
        let msg_f64: MsgSendF64 = std::mem::transmute(objc_msgSend as *const ());
        let msg_f32: MsgSendF32 = std::mem::transmute(objc_msgSend as *const ());
        let msg_rect: MsgSendRect = std::mem::transmute(objc_msgSend as *const ());
        let msg_init_rect: MsgSendRectBoolBool = std::mem::transmute(objc_msgSend as *const ());
        let msg_set_rect: MsgSendSetRect = std::mem::transmute(objc_msgSend as *const ());

        let ns_screen = objc_getClass(c"NSScreen".as_ptr());
        let main_screen = objc_msgSend(ns_screen, sel_registerName(c"mainScreen".as_ptr()));
        if main_screen.is_null() {
            return None;
        }
        let screen_frame = msg_rect(main_screen, sel_registerName(c"frame".as_ptr()));

        let x = (screen_frame.w - panel_w) / 2.0;
        let y_final = screen_frame.y + screen_frame.h - panel_h;
        let y_hidden = screen_frame.y + screen_frame.h;
        let ns_panel_class = objc_getClass(c"NSPanel".as_ptr());
        let panel = objc_msgSend(ns_panel_class, sel_registerName(c"alloc".as_ptr()));
        let content_rect = NSRect {
            x,
            y: y_hidden,
            w: panel_w,
            h: panel_h,
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
            1 << 0,
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
            w: panel_w,
            h: panel_h,
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
        let root_layer = objc_msgSend(content_view, sel_registerName(c"layer".as_ptr()));
        let clear_cg = objc_msgSend(clear_color, sel_registerName(c"CGColor".as_ptr()));
        msg_ptr(
            root_layer,
            sel_registerName(c"setBackgroundColor:".as_ptr()),
            clear_cg,
        );
        msg_ptr(
            panel,
            sel_registerName(c"setContentView:".as_ptr()),
            content_view,
        );
        objc_release(content_view);

        let left = GLOW_PADDING;
        let right = panel_w - GLOW_PADDING;
        let top = panel_h;
        let bottom = GLOW_PADDING;

        let cg_path = CGPathCreateMutable();
        let null_ptr = std::ptr::null::<c_void>();
        CGPathMoveToPoint(cg_path, null_ptr, left, top);
        CGPathAddLineToPoint(cg_path, null_ptr, left, bottom + r);
        CGPathAddArcToPoint(cg_path, null_ptr, left, bottom, left + r, bottom, r);
        CGPathAddLineToPoint(cg_path, null_ptr, right - r, bottom);
        CGPathAddArcToPoint(cg_path, null_ptr, right, bottom, right, bottom + r, r);
        CGPathAddLineToPoint(cg_path, null_ptr, right, top);

        type MsgSendCGSize = unsafe extern "C" fn(*mut c_void, *mut c_void, f64, f64);
        let msg_cgsize: MsgSendCGSize = std::mem::transmute(objc_msgSend as *const ());
        type MsgSendRGBA =
            unsafe extern "C" fn(*mut c_void, *mut c_void, f64, f64, f64, f64) -> *mut c_void;
        let msg_rgba: MsgSendRGBA = std::mem::transmute(objc_msgSend as *const ());

        let ns_color_class = objc_getClass(c"NSColor".as_ptr());
        let rgba_sel = sel_registerName(c"colorWithRed:green:blue:alpha:".as_ptr());

        let rainbow = glow_rgb.is_none();
        let (gr, gg, gb) = glow_rgb.unwrap_or((0.4, 0.7, 1.0));
        let dim_color = msg_rgba(ns_color_class, rgba_sel, gr, gg, gb, 0.20);
        let dim_cg = objc_msgSend(dim_color, sel_registerName(c"CGColor".as_ptr()));
        let bright_color = msg_rgba(ns_color_class, rgba_sel, gr, gg, gb, 1.0);
        let bright_cg = objc_msgSend(bright_color, sel_registerName(c"CGColor".as_ptr()));

        let shape_class = objc_getClass(c"CAShapeLayer".as_ptr());

        let glow_layer = objc_msgSend(shape_class, sel_registerName(c"new".as_ptr()));
        msg_ptr(glow_layer, sel_registerName(c"setPath:".as_ptr()), cg_path);
        msg_ptr(
            glow_layer,
            sel_registerName(c"setStrokeColor:".as_ptr()),
            dim_cg,
        );
        msg_ptr(
            glow_layer,
            sel_registerName(c"setFillColor:".as_ptr()),
            std::ptr::null_mut(),
        );
        msg_f64(
            glow_layer,
            sel_registerName(c"setLineWidth:".as_ptr()),
            GLOW_STROKE_WIDTH + 0.5,
        );
        msg_ptr(
            glow_layer,
            sel_registerName(c"setShadowColor:".as_ptr()),
            dim_cg,
        );
        msg_f64(
            glow_layer,
            sel_registerName(c"setShadowRadius:".as_ptr()),
            GLOW_SHADOW_RADIUS,
        );
        msg_f32(
            glow_layer,
            sel_registerName(c"setShadowOpacity:".as_ptr()),
            0.6,
        );
        msg_cgsize(
            glow_layer,
            sel_registerName(c"setShadowOffset:".as_ptr()),
            0.0,
            0.0,
        );
        msg_ptr(
            root_layer,
            sel_registerName(c"addSublayer:".as_ptr()),
            glow_layer,
        );

        // Rainbow multi-color gradient for Slate accent
        // Shows ALL rainbow colors simultaneously via a scrolling gradient
        // masked to the notch stroke path.
        if rainbow {
            type MsgSendArrayObjs = unsafe extern "C" fn(
                *mut c_void,
                *mut c_void,
                *const *mut c_void,
                u64,
            ) -> *mut c_void;
            let msg_array: MsgSendArrayObjs = std::mem::transmute(objc_msgSend as *const ());
            let ns_array_class = objc_getClass(c"NSArray".as_ptr());
            let arr_sel = sel_registerName(c"arrayWithObjects:count:".as_ptr());
            let cg_color_sel = sel_registerName(c"CGColor".as_ptr());
            type MsgSendSetCGRect2 = unsafe extern "C" fn(*mut c_void, *mut c_void, NSRect);
            let msg_set_cg_rect2: MsgSendSetCGRect2 =
                std::mem::transmute(objc_msgSend as *const ());
            type MsgSendSetCGPoint2 = unsafe extern "C" fn(*mut c_void, *mut c_void, f64, f64);
            let msg_set_point2: MsgSendSetCGPoint2 = std::mem::transmute(objc_msgSend as *const ());
            type MsgSendPtrPtr2 = unsafe extern "C" fn(
                *mut c_void,
                *mut c_void,
                *mut c_void,
                *mut c_void,
            ) -> *mut c_void;
            let msg_ptr_ptr2: MsgSendPtrPtr2 = std::mem::transmute(objc_msgSend as *const ());

            let rainbow_specs: [(f64, f64, f64); 7] = [
                (1.0, 0.3, 0.3), // red
                (1.0, 0.6, 0.2), // orange
                (0.9, 1.0, 0.3), // yellow
                (0.3, 1.0, 0.5), // green
                (0.3, 0.8, 1.0), // cyan
                (0.4, 0.4, 1.0), // blue
                (0.8, 0.3, 1.0), // purple
            ];

            // --- Container layer for gradient + path mask ---
            let ca_layer_class = objc_getClass(c"CALayer".as_ptr());
            let container = objc_msgSend(ca_layer_class, sel_registerName(c"new".as_ptr()));
            let container_rect = NSRect {
                x: 0.0,
                y: 0.0,
                w: panel_w,
                h: panel_h,
            };
            msg_set_cg_rect2(
                container,
                sel_registerName(c"setFrame:".as_ptr()),
                container_rect,
            );

            // --- Rainbow gradient (3x width for seamless scroll loop) ---
            let rainbow_grad_class = objc_getClass(c"CAGradientLayer".as_ptr());
            let rainbow_grad = objc_msgSend(rainbow_grad_class, sel_registerName(c"new".as_ptr()));
            let rainbow_grad_w = panel_w * 3.0;
            let rainbow_grad_rect = NSRect {
                x: 0.0,
                y: 0.0,
                w: rainbow_grad_w,
                h: panel_h,
            };
            msg_set_cg_rect2(
                rainbow_grad,
                sel_registerName(c"setFrame:".as_ptr()),
                rainbow_grad_rect,
            );
            msg_set_point2(
                rainbow_grad,
                sel_registerName(c"setStartPoint:".as_ptr()),
                0.0,
                0.5,
            );
            msg_set_point2(
                rainbow_grad,
                sel_registerName(c"setEndPoint:".as_ptr()),
                1.0,
                0.5,
            );

            // Build gradient colors: full rainbow repeated 3x
            let mut grad_colors: Vec<*mut c_void> = Vec::new();
            for _ in 0..3 {
                for &(cr, cg_c, cb) in &rainbow_specs {
                    let c = msg_rgba(ns_color_class, rgba_sel, cr, cg_c, cb, 0.5);
                    grad_colors.push(objc_msgSend(c, cg_color_sel));
                }
            }
            let close_c = msg_rgba(
                ns_color_class,
                rgba_sel,
                rainbow_specs[0].0,
                rainbow_specs[0].1,
                rainbow_specs[0].2,
                0.5,
            );
            grad_colors.push(objc_msgSend(close_c, cg_color_sel));

            let grad_colors_arr = msg_array(
                ns_array_class,
                arr_sel,
                grad_colors.as_ptr(),
                grad_colors.len() as u64,
            );
            msg_ptr(
                rainbow_grad,
                sel_registerName(c"setColors:".as_ptr()),
                grad_colors_arr,
            );

            msg_ptr(
                container,
                sel_registerName(c"addSublayer:".as_ptr()),
                rainbow_grad,
            );
            objc_release(rainbow_grad);

            // --- Mask: CAShapeLayer with the notch path (stroke only) ---
            let mask_shape = objc_msgSend(shape_class, sel_registerName(c"new".as_ptr()));
            msg_ptr(mask_shape, sel_registerName(c"setPath:".as_ptr()), cg_path);
            let white_mask = msg_rgba(ns_color_class, rgba_sel, 1.0, 1.0, 1.0, 1.0);
            let white_mask_cg = objc_msgSend(white_mask, sel_registerName(c"CGColor".as_ptr()));
            msg_ptr(
                mask_shape,
                sel_registerName(c"setStrokeColor:".as_ptr()),
                white_mask_cg,
            );
            msg_ptr(
                mask_shape,
                sel_registerName(c"setFillColor:".as_ptr()),
                std::ptr::null_mut(),
            );
            msg_f64(
                mask_shape,
                sel_registerName(c"setLineWidth:".as_ptr()),
                GLOW_STROKE_WIDTH + 6.0,
            );
            msg_ptr(
                container,
                sel_registerName(c"setMask:".as_ptr()),
                mask_shape,
            );
            objc_release(mask_shape);

            msg_ptr(
                root_layer,
                sel_registerName(c"addSublayer:".as_ptr()),
                container,
            );
            objc_release(container);

            // --- Animate gradient scroll so rainbow flows along the path ---
            let rb_anim_class = objc_getClass(c"CABasicAnimation".as_ptr());
            let rb_ns_number = objc_getClass(c"NSNumber".as_ptr());
            let scroll_anim = msg_ptr(
                rb_anim_class,
                sel_registerName(c"animationWithKeyPath:".as_ptr()),
                nsstring_cstr(c"position.x"),
            );
            let grad_center_x = rainbow_grad_w / 2.0;
            msg_ptr(
                scroll_anim,
                sel_registerName(c"setFromValue:".as_ptr()),
                msg_f64(
                    rb_ns_number,
                    sel_registerName(c"numberWithDouble:".as_ptr()),
                    grad_center_x,
                ),
            );
            msg_ptr(
                scroll_anim,
                sel_registerName(c"setToValue:".as_ptr()),
                msg_f64(
                    rb_ns_number,
                    sel_registerName(c"numberWithDouble:".as_ptr()),
                    grad_center_x - panel_w,
                ),
            );
            msg_f64(scroll_anim, sel_registerName(c"setDuration:".as_ptr()), 3.0);
            msg_f32(
                scroll_anim,
                sel_registerName(c"setRepeatCount:".as_ptr()),
                f32::MAX,
            );
            msg_ptr_ptr2(
                rainbow_grad,
                sel_registerName(c"addAnimation:forKey:".as_ptr()),
                scroll_anim,
                nsstring_cstr(c"rainbowScroll"),
            );

            // --- Shadow still cycles on glow_layer for ambient glow ---
            let ca_kf_class = objc_getClass(c"CAKeyframeAnimation".as_ptr());
            let anim_kp_sel = sel_registerName(c"animationWithKeyPath:".as_ptr());
            let bright_rainbow: Vec<*mut c_void> = rainbow_specs
                .iter()
                .chain(std::iter::once(&rainbow_specs[0]))
                .map(|&(r, g, b)| {
                    let c = msg_rgba(ns_color_class, rgba_sel, r, g, b, 0.7);
                    objc_msgSend(c, cg_color_sel)
                })
                .collect();
            let shadow_anim = msg_ptr(ca_kf_class, anim_kp_sel, nsstring_cstr(c"shadowColor"));
            let bright_arr = msg_array(
                ns_array_class,
                arr_sel,
                bright_rainbow.as_ptr(),
                bright_rainbow.len() as u64,
            );
            msg_ptr(
                shadow_anim,
                sel_registerName(c"setValues:".as_ptr()),
                bright_arr,
            );
            msg_f64(shadow_anim, sel_registerName(c"setDuration:".as_ptr()), 4.0);
            msg_f32(
                shadow_anim,
                sel_registerName(c"setRepeatCount:".as_ptr()),
                f32::MAX,
            );
            msg_ptr_ptr2(
                glow_layer,
                sel_registerName(c"addAnimation:forKey:".as_ptr()),
                shadow_anim,
                nsstring_cstr(c"rainbowShadow"),
            );

            // Dim the base glow_layer stroke since the gradient provides the color
            let subdued = msg_rgba(ns_color_class, rgba_sel, 0.5, 0.5, 0.5, 0.08);
            let subdued_cg = objc_msgSend(subdued, sel_registerName(c"CGColor".as_ptr()));
            msg_ptr(
                glow_layer,
                sel_registerName(c"setStrokeColor:".as_ptr()),
                subdued_cg,
            );
        }
        objc_release(glow_layer);

        let ns_number = objc_getClass(c"NSNumber".as_ptr());
        let ca_anim_class = objc_getClass(c"CABasicAnimation".as_ptr());
        type MsgSendPtrPtr =
            unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void, *mut c_void) -> *mut c_void;
        let msg_ptr_ptr: MsgSendPtrPtr = std::mem::transmute(objc_msgSend as *const ());
        type MsgSendSetCGRect = unsafe extern "C" fn(*mut c_void, *mut c_void, NSRect);
        let msg_set_cg_rect: MsgSendSetCGRect = std::mem::transmute(objc_msgSend as *const ());
        type MsgSendSetCGPoint = unsafe extern "C" fn(*mut c_void, *mut c_void, f64, f64);
        let msg_set_point: MsgSendSetCGPoint = std::mem::transmute(objc_msgSend as *const ());
        type MsgSendArrayObjs =
            unsafe extern "C" fn(*mut c_void, *mut c_void, *const *mut c_void, u64) -> *mut c_void;
        let msg_array: MsgSendArrayObjs = std::mem::transmute(objc_msgSend as *const ());

        // Comet uses white in rainbow mode, accent color otherwise
        let comet_cg = if rainbow {
            let white_color = msg_rgba(ns_color_class, rgba_sel, 1.0, 1.0, 1.0, 1.0);
            objc_msgSend(white_color, sel_registerName(c"CGColor".as_ptr()))
        } else {
            bright_cg
        };

        let comet = objc_msgSend(shape_class, sel_registerName(c"new".as_ptr()));
        msg_ptr(comet, sel_registerName(c"setPath:".as_ptr()), cg_path);
        msg_ptr(
            comet,
            sel_registerName(c"setStrokeColor:".as_ptr()),
            comet_cg,
        );
        msg_ptr(
            comet,
            sel_registerName(c"setFillColor:".as_ptr()),
            std::ptr::null_mut(),
        );
        msg_f64(
            comet,
            sel_registerName(c"setLineWidth:".as_ptr()),
            GLOW_STROKE_WIDTH + 2.0,
        );
        msg_ptr(
            comet,
            sel_registerName(c"setLineCap:".as_ptr()),
            nsstring_cstr(c"round"),
        );
        msg_ptr(
            comet,
            sel_registerName(c"setShadowColor:".as_ptr()),
            comet_cg,
        );
        msg_f64(
            comet,
            sel_registerName(c"setShadowRadius:".as_ptr()),
            GLOW_SHADOW_RADIUS + 6.0,
        );
        msg_f32(comet, sel_registerName(c"setShadowOpacity:".as_ptr()), 1.0);
        msg_cgsize(
            comet,
            sel_registerName(c"setShadowOffset:".as_ptr()),
            0.0,
            0.0,
        );

        let grad_class = objc_getClass(c"CAGradientLayer".as_ptr());
        let grad = objc_msgSend(grad_class, sel_registerName(c"new".as_ptr()));
        let grad_w = panel_w * 3.0;
        let grad_rect = NSRect {
            x: -panel_w,
            y: 0.0,
            w: grad_w,
            h: panel_h,
        };
        msg_set_cg_rect(grad, sel_registerName(c"setFrame:".as_ptr()), grad_rect);
        msg_set_point(grad, sel_registerName(c"setStartPoint:".as_ptr()), 0.0, 0.5);
        msg_set_point(grad, sel_registerName(c"setEndPoint:".as_ptr()), 1.0, 0.5);

        let clear_cg = objc_msgSend(
            objc_msgSend(ns_color_class, sel_registerName(c"clearColor".as_ptr())),
            sel_registerName(c"CGColor".as_ptr()),
        );
        let white_cg = objc_msgSend(
            objc_msgSend(ns_color_class, sel_registerName(c"whiteColor".as_ptr())),
            sel_registerName(c"CGColor".as_ptr()),
        );
        let colors: [*mut c_void; 5] = [clear_cg, clear_cg, white_cg, clear_cg, clear_cg];
        let colors_arr = msg_array(
            objc_getClass(c"NSArray".as_ptr()),
            sel_registerName(c"arrayWithObjects:count:".as_ptr()),
            colors.as_ptr(),
            5,
        );
        msg_ptr(grad, sel_registerName(c"setColors:".as_ptr()), colors_arr);

        let spot_half = (GLOW_COMET_LENGTH / grad_w) / 2.0;
        let center = 0.5;
        let locs: [*mut c_void; 5] = [
            msg_f64(
                ns_number,
                sel_registerName(c"numberWithDouble:".as_ptr()),
                0.0,
            ),
            msg_f64(
                ns_number,
                sel_registerName(c"numberWithDouble:".as_ptr()),
                center - spot_half,
            ),
            msg_f64(
                ns_number,
                sel_registerName(c"numberWithDouble:".as_ptr()),
                center,
            ),
            msg_f64(
                ns_number,
                sel_registerName(c"numberWithDouble:".as_ptr()),
                center + spot_half,
            ),
            msg_f64(
                ns_number,
                sel_registerName(c"numberWithDouble:".as_ptr()),
                1.0,
            ),
        ];
        let locs_arr = msg_array(
            objc_getClass(c"NSArray".as_ptr()),
            sel_registerName(c"arrayWithObjects:count:".as_ptr()),
            locs.as_ptr(),
            5,
        );
        msg_ptr(grad, sel_registerName(c"setLocations:".as_ptr()), locs_arr);
        msg_ptr(comet, sel_registerName(c"setMask:".as_ptr()), grad);
        msg_ptr(
            root_layer,
            sel_registerName(c"addSublayer:".as_ptr()),
            comet,
        );

        let timing = msg_ptr(
            objc_getClass(c"CAMediaTimingFunction".as_ptr()),
            sel_registerName(c"functionWithName:".as_ptr()),
            nsstring_cstr(c"easeInEaseOut"),
        );
        let anim = msg_ptr(
            ca_anim_class,
            sel_registerName(c"animationWithKeyPath:".as_ptr()),
            nsstring_cstr(c"position.x"),
        );
        msg_ptr(
            anim,
            sel_registerName(c"setFromValue:".as_ptr()),
            msg_f64(
                ns_number,
                sel_registerName(c"numberWithDouble:".as_ptr()),
                0.0,
            ),
        );
        msg_ptr(
            anim,
            sel_registerName(c"setToValue:".as_ptr()),
            msg_f64(
                ns_number,
                sel_registerName(c"numberWithDouble:".as_ptr()),
                panel_w,
            ),
        );
        msg_f64(
            anim,
            sel_registerName(c"setDuration:".as_ptr()),
            GLOW_ORBIT_DURATION,
        );
        msg_f32(
            anim,
            sel_registerName(c"setRepeatCount:".as_ptr()),
            f32::MAX,
        );
        msg_bool(anim, sel_registerName(c"setAutoreverses:".as_ptr()), true);
        msg_ptr(
            anim,
            sel_registerName(c"setTimingFunction:".as_ptr()),
            timing,
        );
        msg_ptr_ptr(
            grad,
            sel_registerName(c"addAnimation:forKey:".as_ptr()),
            anim,
            nsstring_cstr(c"slide"),
        );
        objc_release(grad);
        objc_release(comet);

        CGPathRelease(cg_path);

        objc_msgSend(panel, sel_registerName(c"orderFrontRegardless".as_ptr()));
        let ns_anim = objc_getClass(c"NSAnimationContext".as_ptr());
        objc_msgSend(ns_anim, sel_registerName(c"beginGrouping".as_ptr()));
        let current_ctx = objc_msgSend(ns_anim, sel_registerName(c"currentContext".as_ptr()));
        msg_f64(current_ctx, sel_registerName(c"setDuration:".as_ptr()), 0.2);
        type MsgSend4F =
            unsafe extern "C" fn(*mut c_void, *mut c_void, f32, f32, f32, f32) -> *mut c_void;
        let msg_4f: MsgSend4F = std::mem::transmute(objc_msgSend as *const ());
        let slide_timing = msg_4f(
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
            slide_timing,
        );
        let animator = objc_msgSend(panel, sel_registerName(c"animator".as_ptr()));
        let final_rect = NSRect {
            x,
            y: y_final,
            w: panel_w,
            h: panel_h,
        };
        msg_set_rect(
            animator,
            sel_registerName(c"setFrame:display:".as_ptr()),
            final_rect,
            true,
        );
        objc_msgSend(ns_anim, sel_registerName(c"endGrouping".as_ptr()));

        Some(Arc::new(Mutex::new(NotchGlowState { panel })))
    }
}

pub(in crate::overlay) fn close_notch_glow_panel(state: &NotchGlowState) {
    unsafe {
        objc_msgSend(state.panel, sel_registerName(c"orderOut:".as_ptr()));
        objc_release(state.panel);
    }
}
