#![allow(non_upper_case_globals)]

use std::ffi::c_void;

pub(super) type CFMachPortRef = *mut c_void;
pub(super) type CFRunLoopSourceRef = *mut c_void;
pub(super) type CFRunLoopRef = *mut c_void;
pub(super) type CGEventTapProxy = *mut c_void;
pub(super) type CGEventRef = *mut c_void;
pub(super) type CFAllocatorRef = *const c_void;
pub(super) type CFIndex = isize;
pub(super) type CFStringRef = *const c_void;

pub(super) const kCFAllocatorDefault: CFAllocatorRef = std::ptr::null();
// CGEventTapLocation
pub(super) const kCGSessionEventTap: u32 = 1;

// CGEventTapPlacement
pub(super) const kCGHeadInsertEventTap: u32 = 0;

// CGEventTapOptions
pub(super) const kCGEventTapOptionListenOnly: u32 = 1;

// CGEventType
pub(super) const kCGEventKeyDown: u32 = 10;
pub(super) const kCGEventKeyUp: u32 = 11;
pub(super) const kCGEventFlagsChanged: u32 = 12;
pub(super) const kCGEventTapDisabledByTimeout: u32 = 0xFFFFFFFE;
pub(super) const kCGEventTapDisabledByUserInput: u32 = 0xFFFFFFFF;

// CGEventField
pub(super) const kCGKeyboardEventKeycode: u32 = 9;

// CGEventMask helpers
pub(super) const fn cg_event_mask_bit(event_type: u32) -> u64 {
    1u64 << event_type
}

pub(super) type CGEventTapCallBack = unsafe extern "C" fn(
    proxy: CGEventTapProxy,
    event_type: u32,
    event: CGEventRef,
    user_info: *mut c_void,
) -> CGEventRef;

unsafe extern "C" {
    // CoreGraphics
    pub(super) fn CGEventTapCreate(
        tap: u32,
        place: u32,
        options: u32,
        events_of_interest: u64,
        callback: CGEventTapCallBack,
        user_info: *mut c_void,
    ) -> CFMachPortRef;

    pub(super) fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) -> i64;
    pub(super) fn CGEventGetFlags(event: CGEventRef) -> u64;
    pub(super) fn CGEventTapEnable(tap: CFMachPortRef, enable: bool);

    // CoreFoundation
    pub(super) fn CFMachPortCreateRunLoopSource(
        allocator: CFAllocatorRef,
        port: CFMachPortRef,
        order: CFIndex,
    ) -> CFRunLoopSourceRef;

    pub(super) fn CFRunLoopGetCurrent() -> CFRunLoopRef;
    pub(super) fn CFRunLoopAddSource(
        rl: CFRunLoopRef,
        source: CFRunLoopSourceRef,
        mode: CFStringRef,
    );
    pub(super) fn CFRunLoopRun();
    pub(super) fn CFRelease(cf: *const c_void);

    // We need the real symbol for kCFRunLoopCommonModes.
    #[link_name = "kCFRunLoopCommonModes"]
    pub(super) static kCFRunLoopCommonModes_real: CFStringRef;
}
