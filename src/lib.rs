mod actions;
mod apple_helper;
mod audio;
mod config;
mod hotkey;
mod llm;
mod local_models;
mod menu;
mod model_catalog;
mod overlay;
mod paste;
mod permissions;
mod pipeline;
mod platform;
mod prewarm;
mod startup;
mod state;
mod stt;
mod trace;
mod ui;

mod profile {
    pub use glide_tools::{ProfileCollector, SpanRecord};
}

// Benchmark is separate to keep tool-only code out of the app crate.
#[cfg(feature = "benchmark-support")]
pub mod benchmark_support;

pub fn run() {
    startup::run();
}
