use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
};

use tokio::runtime::Runtime;

use crate::app::state::{RuntimeStatus, SharedState};

mod context;
mod events;
mod ffi;
mod keys;
mod recording;

use context::TapContext;
use events::{event_mask, event_tap_callback};

static LISTENER_RUNNING: AtomicBool = AtomicBool::new(false);

pub fn start_listener(shared: SharedState, runtime: Arc<Runtime>) {
    if LISTENER_RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }

    thread::spawn(move || {
        shared.set_status(RuntimeStatus::Idle);

        let ctx = Box::new(TapContext::new(shared.clone(), runtime));
        let ctx_ptr = Box::into_raw(ctx) as *mut std::ffi::c_void;

        unsafe {
            let tap = ffi::CGEventTapCreate(
                ffi::kCGSessionEventTap,
                ffi::kCGHeadInsertEventTap,
                ffi::kCGEventTapOptionListenOnly,
                event_mask(),
                event_tap_callback,
                ctx_ptr,
            );

            if tap.is_null() {
                let ctx = Box::from_raw(ctx_ptr as *mut TapContext);
                LISTENER_RUNNING.store(false, Ordering::SeqCst);
                tracing::error!(
                    "Failed to create event tap. Grant Input Monitoring permission in \
                     System Settings > Privacy & Security > Input Monitoring and relaunch."
                );
                ctx.shared.set_error();
                return;
            }

            (*(ctx_ptr as *mut TapContext)).tap = tap;

            let source = ffi::CFMachPortCreateRunLoopSource(ffi::kCFAllocatorDefault, tap, 0);
            let run_loop = ffi::CFRunLoopGetCurrent();
            ffi::CFRunLoopAddSource(run_loop, source, ffi::kCFRunLoopCommonModes_real);

            // This blocks forever (like rdev::listen did).
            ffi::CFRunLoopRun();

            ffi::CFRelease(source);
            ffi::CFRelease(tap);
            let _ = Box::from_raw(ctx_ptr as *mut TapContext);
            LISTENER_RUNNING.store(false, Ordering::SeqCst);
        }
    });
}
