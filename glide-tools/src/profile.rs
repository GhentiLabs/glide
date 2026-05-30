use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SpanRecord {
    pub phase: String,
    pub duration_ms: f64,
}

#[derive(Clone, Default)]
pub struct ProfileCollector {
    inner: Option<Arc<ProfileState>>,
}

#[derive(Default)]
struct ProfileState {
    spans: Mutex<Vec<SpanRecord>>,
    markers: Mutex<BTreeMap<String, Instant>>,
}

impl ProfileCollector {
    pub fn enabled() -> Self {
        Self {
            inner: Some(Arc::new(ProfileState::default())),
        }
    }

    pub fn disabled() -> Self {
        Self { inner: None }
    }

    pub fn is_enabled(&self) -> bool {
        self.inner.is_some()
    }

    pub fn record(&self, phase: impl Into<String>, duration: Duration) {
        if let Some(inner) = &self.inner
            && let Ok(mut spans) = inner.spans.lock()
        {
            spans.push(SpanRecord {
                phase: phase.into(),
                duration_ms: duration.as_secs_f64() * 1000.0,
            });
        }
    }

    pub fn measure<T>(&self, phase: &str, f: impl FnOnce() -> T) -> T {
        let started = Instant::now();
        let result = f();
        self.record(phase, started.elapsed());
        result
    }

    pub fn measure_result<T>(&self, phase: &str, f: impl FnOnce() -> Result<T>) -> Result<T> {
        let started = Instant::now();
        let result = f();
        self.record(phase, started.elapsed());
        result
    }

    pub fn mark(&self, marker: impl Into<String>) {
        if let Some(inner) = &self.inner
            && let Ok(mut markers) = inner.markers.lock()
        {
            markers.insert(marker.into(), Instant::now());
        }
    }

    pub fn record_since_marker(&self, marker: &str, phase: impl Into<String>) {
        let Some(started) = self.inner.as_ref().and_then(|inner| {
            inner
                .markers
                .lock()
                .ok()
                .and_then(|markers| markers.get(marker).copied())
        }) else {
            return;
        };
        self.record(phase, started.elapsed());
    }

    pub fn spans(&self) -> Vec<SpanRecord> {
        self.inner
            .as_ref()
            .and_then(|inner| inner.spans.lock().ok().map(|spans| spans.clone()))
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::ProfileCollector;

    #[test]
    fn records_only_when_enabled() {
        let disabled = ProfileCollector::disabled();
        disabled.record("phase", Duration::from_millis(10));
        disabled.mark("start");
        disabled.record_since_marker("start", "since_start");
        assert!(disabled.spans().is_empty());

        let enabled = ProfileCollector::enabled();
        enabled.mark("release");
        std::thread::sleep(Duration::from_millis(1));
        enabled.record_since_marker("release", "release_to_send");

        let spans = enabled.spans();
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].phase, "release_to_send");
        assert!(spans[0].duration_ms > 0.0);
    }
}
