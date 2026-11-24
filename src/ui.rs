//! The settings window: the [`SettingsApp`] view, its state, and construction.
//!
//! Behaviour is split across sibling modules:
//! - [`builders`] constructs the editable input-field entities and drafts config
//! - [`persistence`] debounced autosave back to config
//! - [`render`] draws the window shell and dispatches to the active pane
//! - [`panes`] render each settings section (general, styles, providers, …)
//! - [`theme`] applies the theme/accent colour
//! - [`onboarding`] the first-run overlay

mod about;
mod builders;
mod config_recovery;
mod helpers;
pub(crate) mod menu;
pub(crate) mod onboarding;
pub(crate) mod overlay;
mod panes;
mod persistence;
mod render;
mod theme;

use std::time::Duration;

use gpui::prelude::*;
use gpui::{Entity, Subscription};
use gpui_component::input::InputState;

use crate::app::state::SharedState;
use crate::config::Provider;
use crate::platform::permissions;

pub(crate) use about::AboutView;
pub(crate) use config_recovery::open_config_recovery_window;
pub(crate) use theme::apply_theme_preference;

const AUTOSAVE_DELAY: Duration = Duration::from_millis(800);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SettingsPane {
    Providers,
    Styles,
    General,
    Dictionary,
}

struct ProviderInputs {
    provider: Provider,
    api_key: Entity<InputState>,
    base_url: Entity<InputState>,
}

pub(crate) struct StyleInputs {
    name: Entity<InputState>,
    apps: Vec<String>,
    prompt: Entity<InputState>,
    prompt_expanded: bool,
    search: Entity<InputState>,
    stt_model_search: Entity<InputState>,
    llm_model_search: Entity<InputState>,
}

pub struct SettingsApp {
    shared: SharedState,
    active_pane: SettingsPane,
    sidebar_collapsed: bool,
    recording_hotkey: bool,
    recording_toggle_hotkey: bool,

    provider_inputs: Vec<ProviderInputs>,
    expanded_provider: Option<Provider>,
    apple_speech_search: Entity<InputState>,
    expanded_style: Option<usize>,
    prompt_expanded: bool,

    default_prompt: Entity<InputState>,
    default_stt_search: Entity<InputState>,
    default_llm_search: Entity<InputState>,
    styles: Vec<StyleInputs>,

    last_fetched_providers: crate::config::ProvidersConfig,

    save_pending: bool,

    // Dictionary inputs
    vocabulary_input: Entity<InputState>,
    replacement_find_input: Entity<InputState>,
    replacement_replace_input: Entity<InputState>,

    // Onboarding overlay state
    show_onboarding: bool,
    onboarding_step: onboarding::OnboardingStep,
    onboarding_perm_state: onboarding::PermissionState,
    permission_statuses: Vec<permissions::PermissionStatus>,
    onboarding_selected_trigger: Option<crate::config::HotkeyTrigger>,
    onboarding_recording_custom: bool,

    _subscriptions: Vec<Subscription>,
}

impl SettingsApp {
    pub fn new(
        shared: SharedState,
        window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> Self {
        let config = shared.snapshot().config;

        let default_prompt = cx.new(|cx| {
            InputState::new(window, cx)
                .auto_grow(3, 12)
                .default_value(&config.dictation.system_prompt)
        });
        let default_stt_search = cx.new(|cx| InputState::new(window, cx));
        let default_llm_search = cx.new(|cx| InputState::new(window, cx));
        let apple_speech_search = cx.new(|cx| InputState::new(window, cx));
        let vocabulary_input = cx.new(|cx| InputState::new(window, cx));
        let replacement_find_input = cx.new(|cx| InputState::new(window, cx));
        let replacement_replace_input = cx.new(|cx| InputState::new(window, cx));

        let mut subs = vec![cx.subscribe_in(&default_prompt, window, Self::on_input_change)];
        let provider_inputs = Provider::REMOTE
            .into_iter()
            .map(|provider| {
                let (inputs, provider_subs) = Self::create_provider_inputs(
                    provider,
                    config.providers.credentials_for(provider),
                    window,
                    cx,
                );
                subs.extend(provider_subs);
                inputs
            })
            .collect();

        let styles: Vec<_> = config
            .dictation
            .styles
            .iter()
            .map(|entry| {
                let (inputs, entry_subs) = Self::create_style_inputs(entry, window, cx);
                subs.extend(entry_subs);
                inputs
            })
            .collect();

        let theme_shared = shared.clone();
        subs.push(
            cx.observe_window_appearance(window, move |_this, window, cx| {
                let snap = theme_shared.snapshot();
                apply_theme_preference(
                    snap.config.app.theme,
                    snap.config.app.accent,
                    Some(window),
                    cx,
                );
            }),
        );
        subs.push(cx.observe_window_activation(window, |this, window, cx| {
            if window.is_window_active() && this.refresh_permissions() {
                cx.notify();
            }
        }));

        // The startup fetch (spawned before this window exists) applies smart
        // defaults from its completion callback; generation 0 means "any
        // completed fetch", covering windows opened before or after it.
        Self::notify_when_models_refresh(0, cx);

        let show_onboarding = !config.app.onboarding_completed;
        let permission_statuses = permissions::check_all();
        let onboarding_perm_state =
            onboarding::PermissionState::from_statuses(&permission_statuses);

        Self {
            shared,
            active_pane: SettingsPane::General,
            sidebar_collapsed: false,
            recording_hotkey: false,
            recording_toggle_hotkey: false,
            provider_inputs,
            expanded_provider: Some(Provider::OpenAi),
            apple_speech_search,
            expanded_style: Some(0),
            prompt_expanded: false,
            default_prompt,
            default_stt_search,
            default_llm_search,
            styles,
            last_fetched_providers: config.providers.clone(),
            save_pending: false,
            vocabulary_input,
            replacement_find_input,
            replacement_replace_input,
            show_onboarding,
            onboarding_step: onboarding::OnboardingStep::Welcome,
            onboarding_perm_state,
            permission_statuses,
            onboarding_selected_trigger: Some(onboarding::default_hotkey_preset()),
            onboarding_recording_custom: false,
            _subscriptions: subs,
        }
    }

    fn refresh_permissions(&mut self) -> bool {
        let next_statuses = permissions::check_all();
        let next_state = onboarding::PermissionState::from_statuses(&next_statuses);
        let statuses_changed = self.permission_statuses != next_statuses;
        let state_changed = self.onboarding_perm_state != next_state;

        if statuses_changed {
            self.permission_statuses = next_statuses;
        }
        if state_changed {
            self.onboarding_perm_state = next_state;
        }

        statuses_changed || state_changed
    }
}

#[cfg(test)]
mod tests;
