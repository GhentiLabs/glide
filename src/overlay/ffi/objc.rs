pub(in crate::overlay) use std::ffi::c_void;
use std::ffi::{CStr, c_char};

pub(in crate::overlay) const NOTCH_WIDTH_FALLBACK: u32 = 180;
pub(in crate::overlay) const NOTCH_HEIGHT_FALLBACK: f64 = 37.0;
pub(in crate::overlay) const NOTCH_HEIGHT: f64 = 60.0;
pub(in crate::overlay) const NOTCH_CORNER_RADIUS: f64 = 10.0;
pub(in crate::overlay) const NOTCH_BAR_COUNT: usize = 16;
pub(in crate::overlay) const NOTCH_BAR_GAP: f64 = 2.0;
pub(in crate::overlay) const NOTCH_BAR_WIDTH: f64 = 4.0;
pub(in crate::overlay) const NOTCH_DOT_COUNT: usize = 3;
pub(in crate::overlay) const NOTCH_DOT_GAP: f64 = 8.0;
pub(in crate::overlay) const NOTCH_DOT_SIZE: f64 = 6.0;
pub(in crate::overlay) const NOTCH_BAR_TOP_INSET: f64 = 6.0;
pub(in crate::overlay) const NOTCH_BAR_MAX_HEIGHT: f64 = 40.0;
pub(in crate::overlay) const NOTCH_DOT_BOTTOM_INSET: f64 = 12.0;

pub(in crate::overlay) const GLOW_PADDING: f64 = 28.0;
pub(in crate::overlay) const GLOW_STROKE_WIDTH: f64 = 5.5;
pub(in crate::overlay) const GLOW_SHADOW_RADIUS: f64 = 20.0;
pub(in crate::overlay) const GLOW_CORNER_RADIUS: f64 = 14.0;
pub(in crate::overlay) const GLOW_ORBIT_DURATION: f64 = 1.4;
pub(in crate::overlay) const GLOW_COMET_LENGTH: f64 = 120.0;

// ---------------------------------------------------------------------------
// Objective-C / CoreGraphics FFI
// ---------------------------------------------------------------------------

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}
#[link(name = "QuartzCore", kind = "framework")]
unsafe extern "C" {}
#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {}

unsafe extern "C" {
    pub(in crate::overlay) fn objc_getClass(name: *const c_char) -> *mut c_void;
    pub(in crate::overlay) fn sel_registerName(name: *const c_char) -> *mut c_void;
    pub(in crate::overlay) fn objc_msgSend(receiver: *mut c_void, sel: *mut c_void) -> *mut c_void;
}

unsafe extern "C" {
    pub(in crate::overlay) fn CGPathCreateMutable() -> *mut c_void;
    pub(in crate::overlay) fn CGPathMoveToPoint(
        path: *mut c_void,
        m: *const c_void,
        x: f64,
        y: f64,
    );
    pub(in crate::overlay) fn CGPathAddLineToPoint(
        path: *mut c_void,
        m: *const c_void,
        x: f64,
        y: f64,
    );
    pub(in crate::overlay) fn CGPathAddArcToPoint(
        path: *mut c_void,
        m: *const c_void,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        radius: f64,
    );
    pub(in crate::overlay) fn CGPathRelease(path: *mut c_void);
}

pub(in crate::overlay) unsafe fn nsstring_cstr(s: &CStr) -> *mut c_void {
    unsafe {
        let msg_ptr: MsgSendPtr = std::mem::transmute(objc_msgSend as *const ());
        msg_ptr(
            objc_getClass(c"NSString".as_ptr()),
            sel_registerName(c"stringWithUTF8String:".as_ptr()),
            s.as_ptr() as *mut c_void,
        )
    }
}

pub(in crate::overlay) unsafe fn objc_release(obj: *mut c_void) {
    unsafe {
        objc_msgSend(obj, sel_registerName(c"release".as_ptr()));
    }
}

pub(in crate::overlay) type MsgSendF64 =
    unsafe extern "C" fn(*mut c_void, *mut c_void, f64) -> *mut c_void;
pub(in crate::overlay) type MsgSendF32 =
    unsafe extern "C" fn(*mut c_void, *mut c_void, f32) -> *mut c_void;
pub(in crate::overlay) type MsgSendBool =
    unsafe extern "C" fn(*mut c_void, *mut c_void, bool) -> *mut c_void;
pub(in crate::overlay) type MsgSendI64 =
    unsafe extern "C" fn(*mut c_void, *mut c_void, i64) -> *mut c_void;
pub(in crate::overlay) type MsgSendU64 =
    unsafe extern "C" fn(*mut c_void, *mut c_void, u64) -> *mut c_void;
pub(in crate::overlay) type MsgSendPtr =
    unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> *mut c_void;
pub(in crate::overlay) type MsgSendRect = unsafe extern "C" fn(*mut c_void, *mut c_void) -> NSRect;
pub(in crate::overlay) type MsgSendRectBoolBool =
    unsafe extern "C" fn(*mut c_void, *mut c_void, NSRect, u64, u64, bool) -> *mut c_void;
pub(in crate::overlay) type MsgSendSetRect =
    unsafe extern "C" fn(*mut c_void, *mut c_void, NSRect, bool);

#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub(in crate::overlay) struct NSRect {
    pub(in crate::overlay) x: f64,
    pub(in crate::overlay) y: f64,
    pub(in crate::overlay) w: f64,
    pub(in crate::overlay) h: f64,
}
