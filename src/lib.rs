//! Glide — macOS push-to-talk dictation.

// Core dictation flow
mod audio;
mod config;
mod pipeline; // record → transcribe → clean up → paste

// Application lifecycle & shared state
mod app; // startup, state, window actions, tracing

// Speech & text engines
mod engines; // stt, llm, local_models, model_catalog, apple_helper

// macOS platform integration
mod platform; // macos APIs, permissions, paste, input/hotkey

// User interface
mod ui; // settings window, overlay, menu

mod profile {
    pub use glide_tools::{ProfileCollector, SpanRecord};
}

// Benchmark is separate cause I don't like bloat.
#[cfg(feature = "benchmark-support")]
pub mod benchmark_support;

pub fn run() {
    app::startup::run();
}
