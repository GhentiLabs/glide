use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum DownloadFinish {
    Cleared,
    Failed,
    Cancelled,
    Stale,
}

#[derive(Clone)]
pub(super) struct DownloadRun {
    id: String,
    run_id: u64,
    cancel_token: Arc<AtomicBool>,
}

impl DownloadRun {
    fn new(id: &str, run_id: u64, cancel_token: Arc<AtomicBool>) -> Self {
        Self {
            id: id.to_string(),
            run_id,
            cancel_token,
        }
    }

    pub(super) fn id(&self) -> &str {
        &self.id
    }

    pub(super) fn run_id(&self) -> u64 {
        self.run_id
    }

    pub(super) fn is_cancelled(&self) -> bool {
        self.cancel_token.load(Ordering::SeqCst)
    }
}

#[derive(Clone)]
struct ActiveDownload {
    run_id: u64,
    cancel_token: Arc<AtomicBool>,
}

impl ActiveDownload {
    fn to_run(&self, id: &str) -> DownloadRun {
        DownloadRun::new(id, self.run_id, self.cancel_token.clone())
    }
}

struct DownloadEntry<State> {
    state: State,
    active: Option<ActiveDownload>,
}

pub(super) struct DownloadRegistry<State> {
    entries: Mutex<HashMap<String, DownloadEntry<State>>>,
    next_run_id: AtomicU64,
}

impl<State: Clone> DownloadRegistry<State> {
    pub(super) fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            next_run_id: AtomicU64::new(1),
        }
    }

    pub(super) fn begin(&self, id: &str, state: State) -> Option<DownloadRun> {
        let mut entries = self.entries.lock().ok()?;
        if entries
            .get(id)
            .and_then(|entry| entry.active.as_ref())
            .is_some()
        {
            return None;
        }

        let run_id = self.next_run_id.fetch_add(1, Ordering::SeqCst);
        let active = ActiveDownload {
            run_id,
            cancel_token: Arc::new(AtomicBool::new(false)),
        };
        let run = active.to_run(id);
        entries.insert(
            id.to_string(),
            DownloadEntry {
                state,
                active: Some(active),
            },
        );
        Some(run)
    }

    pub(super) fn state(&self, id: &str) -> Option<State> {
        self.entries
            .lock()
            .ok()
            .and_then(|entries| entries.get(id).map(|entry| entry.state.clone()))
    }

    pub(super) fn is_active(&self, id: &str) -> bool {
        self.entries
            .lock()
            .ok()
            .and_then(|entries| entries.get(id).map(|entry| entry.active.is_some()))
            .unwrap_or(false)
    }

    pub(super) fn any_active(&self) -> bool {
        self.entries
            .lock()
            .map(|entries| entries.values().any(|entry| entry.active.is_some()))
            .unwrap_or(false)
    }

    pub(super) fn clear(&self, id: &str) {
        if let Ok(mut entries) = self.entries.lock() {
            entries.remove(id);
        }
    }

    pub(super) fn request_cancel(
        &self,
        id: &str,
        to_cancelling: impl FnOnce(&State) -> State,
    ) -> Option<DownloadRun> {
        let mut entries = self.entries.lock().ok()?;
        let entry = entries.get_mut(id)?;
        let active = entry.active.as_ref()?;
        active.cancel_token.store(true, Ordering::SeqCst);
        let run = active.to_run(id);
        entry.state = to_cancelling(&entry.state);
        Some(run)
    }

    pub(super) fn update_if_current(
        &self,
        run: &DownloadRun,
        state: State,
        should_update: impl FnOnce(&State) -> bool,
    ) -> bool {
        let Ok(mut entries) = self.entries.lock() else {
            return false;
        };
        let Some(entry) = entries.get_mut(run.id()) else {
            return false;
        };
        if !matches_current_run(entry, run) || !should_update(&entry.state) {
            return false;
        }

        entry.state = state;
        true
    }

    pub(super) fn finish_clear(&self, run: &DownloadRun) -> DownloadFinish {
        let Ok(mut entries) = self.entries.lock() else {
            return DownloadFinish::Stale;
        };
        if entries
            .get(run.id())
            .is_some_and(|entry| matches_current_run(entry, run))
        {
            entries.remove(run.id());
            DownloadFinish::Cleared
        } else {
            DownloadFinish::Stale
        }
    }

    pub(super) fn finish_error(&self, run: &DownloadRun, failed_state: State) -> DownloadFinish {
        let Ok(mut entries) = self.entries.lock() else {
            return DownloadFinish::Stale;
        };
        let Some(entry) = entries.get_mut(run.id()) else {
            return DownloadFinish::Stale;
        };
        if !matches_current_run(entry, run) {
            return DownloadFinish::Stale;
        }

        if run.is_cancelled() {
            entries.remove(run.id());
            DownloadFinish::Cancelled
        } else {
            entry.state = failed_state;
            entry.active = None;
            DownloadFinish::Failed
        }
    }

    #[cfg(test)]
    pub(super) fn set_state_for_test(&self, id: &str, state: State, active: bool) {
        if active {
            self.set_active_for_test(id, state);
        } else {
            self.set_inactive_for_test(id, state);
        }
    }

    #[cfg(test)]
    pub(super) fn set_inactive_for_test(&self, id: &str, state: State) {
        if let Ok(mut entries) = self.entries.lock() {
            entries.insert(
                id.to_string(),
                DownloadEntry {
                    state,
                    active: None,
                },
            );
        }
    }

    #[cfg(test)]
    pub(super) fn set_active_for_test(&self, id: &str, state: State) -> DownloadRun {
        let run_id = self.next_run_id.fetch_add(1, Ordering::SeqCst);
        let active = ActiveDownload {
            run_id,
            cancel_token: Arc::new(AtomicBool::new(false)),
        };
        let run = active.to_run(id);
        let mut entries = self.entries.lock().expect("download registry poisoned");
        entries.insert(
            id.to_string(),
            DownloadEntry {
                state,
                active: Some(active),
            },
        );
        run
    }
}

fn matches_current_run<State>(entry: &DownloadEntry<State>, run: &DownloadRun) -> bool {
    entry
        .active
        .as_ref()
        .is_some_and(|active| active.run_id == run.run_id())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Debug, PartialEq, Eq)]
    enum TestState {
        Downloading(u64),
        Cancelling(u64),
        Failed,
    }

    #[test]
    fn cancel_flips_current_run_token() {
        let registry = DownloadRegistry::new();
        let run = registry.begin("model", TestState::Downloading(10)).unwrap();

        let cancelled = registry
            .request_cancel("model", |state| match state {
                TestState::Downloading(progress) | TestState::Cancelling(progress) => {
                    TestState::Cancelling(*progress)
                }
                TestState::Failed => TestState::Failed,
            })
            .unwrap();

        assert_eq!(cancelled.run_id(), run.run_id());
        assert!(run.is_cancelled());
        assert_eq!(registry.state("model"), Some(TestState::Cancelling(10)));
    }

    #[test]
    fn stale_run_cannot_clear_or_fail_newer_run() {
        let registry = DownloadRegistry::new();
        let stale = registry.begin("model", TestState::Downloading(1)).unwrap();
        registry.finish_clear(&stale);
        let current = registry.begin("model", TestState::Downloading(2)).unwrap();

        assert_eq!(
            registry.finish_error(&stale, TestState::Failed),
            DownloadFinish::Stale
        );
        assert_eq!(registry.state("model"), Some(TestState::Downloading(2)));

        registry.finish_clear(&current);
        assert_eq!(registry.state("model"), None);
    }

    #[test]
    fn progress_update_does_not_overwrite_cancelling_state() {
        let registry = DownloadRegistry::new();
        let run = registry.begin("model", TestState::Downloading(1)).unwrap();
        registry.request_cancel("model", |state| match state {
            TestState::Downloading(progress) | TestState::Cancelling(progress) => {
                TestState::Cancelling(*progress)
            }
            TestState::Failed => TestState::Failed,
        });

        assert!(
            !registry.update_if_current(&run, TestState::Downloading(2), |state| matches!(
                state,
                TestState::Downloading(_)
            ),)
        );
        assert_eq!(registry.state("model"), Some(TestState::Cancelling(1)));
    }

    #[test]
    fn retry_after_failure_gets_fresh_uncancelled_token() {
        let registry = DownloadRegistry::new();
        let first = registry.begin("model", TestState::Downloading(1)).unwrap();
        assert_eq!(
            registry.finish_error(&first, TestState::Failed),
            DownloadFinish::Failed
        );

        let retry = registry.begin("model", TestState::Downloading(0)).unwrap();

        assert_ne!(first.run_id(), retry.run_id());
        assert!(!retry.is_cancelled());
        assert_eq!(registry.state("model"), Some(TestState::Downloading(0)));
    }
}
