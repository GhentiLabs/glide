//! Debounced autosave: input changes schedule a delayed save that writes the
//! current draft back to config and refreshes models when providers change.

use std::time::Duration;

use gpui::Entity;
use gpui_component::input::{InputEvent, InputState};

use super::{AUTOSAVE_DELAY, SettingsApp};

impl SettingsApp {
    pub(in crate::ui) fn on_input_change(
        &mut self,
        _emitter: &Entity<InputState>,
        event: &InputEvent,
        _window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) {
        if matches!(event, InputEvent::Change) {
            self.schedule_autosave(cx);
        }
    }

    pub(in crate::ui) fn schedule_autosave(&mut self, cx: &mut gpui::Context<Self>) {
        if !self.save_pending {
            self.save_pending = true;
            cx.spawn(async move |this, cx| {
                cx.background_executor().timer(AUTOSAVE_DELAY).await;
                this.update(cx, |this, cx| {
                    this.save_pending = false;
                    this.save(cx);
                })
                .ok();
            })
            .detach();
        }
    }

    fn save(&mut self, cx: &gpui::Context<Self>) {
        let draft = self.draft_from_inputs(cx);
        let providers_changed = draft.providers != self.last_fetched_providers;
        let providers = draft.providers.clone();
        let _ = self.shared.update_config(move |config| *config = draft);
        if providers_changed {
            self.last_fetched_providers = providers.clone();
            let initial = crate::engines::model_catalog::fetch_generation();
            let shared = self.shared.clone();
            crate::engines::model_catalog::fetch_all_models(&providers, move || {
                let _ = shared.update_config(crate::engines::model_catalog::apply_smart_defaults);
            });
            Self::notify_when_models_refresh(initial, cx);
        }
    }

    /// Redraws once the fetch generation moves past `initial_generation` (or
    /// after a timeout beyond the fetch's own), so repaired selections show up
    /// as soon as they are saved.
    pub(in crate::ui) fn notify_when_models_refresh(
        initial_generation: u64,
        cx: &gpui::Context<Self>,
    ) {
        // Worst case is 6 sequential requests at the 10s client timeout: one
        // GET per provider (4) plus ElevenLabs's models+user fallback pair
        // (2) = 60s; 280 x 250ms = 70s adds slack. Bump if a provider is added.
        cx.spawn(async move |this, cx| {
            for _ in 0..280 {
                if crate::engines::model_catalog::fetch_generation() != initial_generation {
                    break;
                }
                cx.background_executor()
                    .timer(Duration::from_millis(250))
                    .await;
            }
            let _ = this.update(cx, |_this, cx| cx.notify());
        })
        .detach();
    }
}
