mod apple_helper;
mod audio;
mod config;
mod hotkey;
mod llm;
mod local_models;
mod model_catalog;
mod overlay;
mod paste;
mod permissions;
mod pipeline;
mod platform;
mod startup;
mod state;
mod stt;
mod ui;

pub fn run() {
    startup::run();
}
