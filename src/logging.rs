//! File + stderr logging and panic capture.
//!
//! Logs go to `~/Library/Logs/Glide/glide.log.<date>` (daily rotation) so a
//! packaged app leaves a trace users can send with bug reports; stderr stays
//! active for development runs. `RUST_LOG` overrides the default `info` level.

use std::io::IsTerminal as _;
use std::path::PathBuf;
use std::sync::OnceLock;

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt as _, util::SubscriberInitExt as _};

static LOG_GUARD: OnceLock<WorkerGuard> = OnceLock::new();

pub fn init() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    let file_layer = log_directory().map(|directory| {
        let appender = tracing_appender::rolling::daily(directory, "glide.log");
        let (writer, guard) = tracing_appender::non_blocking(appender);
        let _ = LOG_GUARD.set(guard);
        fmt::layer().with_writer(writer).with_ansi(false)
    });

    // Skip the stderr layer when detached (packaged .app) — it goes nowhere.
    let stderr_layer = std::io::stderr()
        .is_terminal()
        .then(|| fmt::layer().with_writer(std::io::stderr));

    tracing_subscriber::registry()
        .with(filter)
        .with(file_layer)
        .with(stderr_layer)
        .init();

    install_panic_hook();

    tracing::info!(version = env!("CARGO_PKG_VERSION"), "Glide starting");
}

/// Rust panics unwind and exit without tripping macOS's crash reporter, so the
/// log file is the only record a panic leaves.
fn install_panic_hook() {
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let location = info
            .location()
            .map(|location| location.to_string())
            .unwrap_or_else(|| "unknown location".to_string());
        let backtrace = std::backtrace::Backtrace::force_capture();
        tracing::error!(%location, "panic: {info}\nbacktrace:\n{backtrace}");
        default_hook(info);
    }));
}

fn log_directory() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Library/Logs/Glide"))
}

#[cfg(test)]
mod tests {
    use super::log_directory;

    #[test]
    fn log_directory_is_under_user_library_logs() {
        let directory = log_directory().expect("HOME should be set in tests");
        assert!(directory.ends_with("Library/Logs/Glide"), "{directory:?}");
    }
}
