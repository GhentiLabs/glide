mod helpers;
pub(crate) mod onboarding;
mod panes;

use std::time::Duration;

use gpui::prelude::*;
use gpui::{App, Entity, SharedString, Subscription, Window, div};
use gpui_component::ActiveTheme;
use gpui_component::Side;
use gpui_component::Sizable;
use gpui_component::button::{Button, ButtonVariants};
use gpui_component::input::{InputEvent, InputState};
use gpui_component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_component::sidebar::{Sidebar, SidebarMenu, SidebarMenuItem, SidebarToggleButton};
use gpui_component::theme::{Theme, ThemeMode};
use gpui_component::{Icon, IconName};

use crate::config::{ColorAccent, GlideConfig, Style, ThemePreference};
use crate::permissions;
use crate::state::SharedState;

const AUTOSAVE_DELAY: Duration = Duration::from_millis(800);

pub fn apply_theme_preference(
    pref: ThemePreference,
    accent: ColorAccent,
    window: Option<&mut Window>,
    cx: &mut App,
) {
    match pref {
        ThemePreference::System => Theme::sync_system_appearance(window, cx),
        ThemePreference::Light => Theme::change(ThemeMode::Light, window, cx),
        ThemePreference::Dark => Theme::change(ThemeMode::Dark, window, cx),
    }

    // Apply accent color overrides on top of the base light/dark theme
    let (h, s, l, a) = accent.primary_hsla();
    let (hh, sh, lh, ah) = accent.primary_hover_hsla();
    let (ha, sa, la, aa) = accent.primary_active_hsla();
    let theme = cx.global_mut::<Theme>();
    theme.colors.primary = gpui::hsla(h, s, l, a);
    theme.colors.primary_hover = gpui::hsla(hh, sh, lh, ah);
    theme.colors.primary_active = gpui::hsla(ha, sa, la, aa);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SettingsPane {
    Providers,
    Styles,
    General,
    Dictionary,
}

struct ProviderInputs {
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

    openai_inputs: ProviderInputs,
    groq_inputs: ProviderInputs,
    cerebras_inputs: ProviderInputs,
    fireworks_inputs: ProviderInputs,
    elevenlabs_inputs: ProviderInputs,
    expanded_provider: Option<usize>,
    apple_speech_search: Entity<InputState>,
    expanded_style: Option<usize>,
    prompt_expanded: bool,

    default_prompt: Entity<InputState>,
    default_stt_search: Entity<InputState>,
    default_llm_search: Entity<InputState>,
    styles: Vec<StyleInputs>,

    last_fetched_openai_key: String,
    last_fetched_groq_key: String,
    last_fetched_cerebras_key: String,
    last_fetched_fireworks_key: String,
    last_fetched_elevenlabs_key: String,
    last_fetched_openai_base_url: String,
    last_fetched_groq_base_url: String,
    last_fetched_cerebras_base_url: String,
    last_fetched_fireworks_base_url: String,
    last_fetched_elevenlabs_base_url: String,

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

        let openai_creds = &config.providers.openai;
        let openai_api_key = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .default_value(&openai_creds.api_key)
        });
        let openai_base_url =
            cx.new(|cx| InputState::new(window, cx).default_value(&openai_creds.base_url));

        let groq_creds = &config.providers.groq;
        let groq_api_key = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .default_value(&groq_creds.api_key)
        });
        let groq_base_url =
            cx.new(|cx| InputState::new(window, cx).default_value(&groq_creds.base_url));

        let cerebras_creds = &config.providers.cerebras;
        let cerebras_api_key = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .default_value(&cerebras_creds.api_key)
        });
        let cerebras_base_url =
            cx.new(|cx| InputState::new(window, cx).default_value(&cerebras_creds.base_url));

        let fireworks_creds = &config.providers.fireworks;
        let fireworks_api_key = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .default_value(&fireworks_creds.api_key)
        });
        let fireworks_base_url =
            cx.new(|cx| InputState::new(window, cx).default_value(&fireworks_creds.base_url));

        let elevenlabs_creds = &config.providers.elevenlabs;
        let elevenlabs_api_key = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .default_value(&elevenlabs_creds.api_key)
        });
        let elevenlabs_base_url =
            cx.new(|cx| InputState::new(window, cx).default_value(&elevenlabs_creds.base_url));

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

        let mut subs = vec![
            cx.subscribe_in(&openai_api_key, window, Self::on_input_change),
            cx.subscribe_in(&openai_base_url, window, Self::on_input_change),
            cx.subscribe_in(&groq_api_key, window, Self::on_input_change),
            cx.subscribe_in(&groq_base_url, window, Self::on_input_change),
            cx.subscribe_in(&cerebras_api_key, window, Self::on_input_change),
            cx.subscribe_in(&cerebras_base_url, window, Self::on_input_change),
            cx.subscribe_in(&fireworks_api_key, window, Self::on_input_change),
            cx.subscribe_in(&fireworks_base_url, window, Self::on_input_change),
            cx.subscribe_in(&elevenlabs_api_key, window, Self::on_input_change),
            cx.subscribe_in(&elevenlabs_base_url, window, Self::on_input_change),
            cx.subscribe_in(&default_prompt, window, Self::on_input_change),
        ];

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

        let shared_for_defaults = shared.clone();
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            if crate::model_catalog::any_provider_verified() {
                let _ = shared_for_defaults.update_config(|config| {
                    crate::model_catalog::apply_smart_defaults_initial(config);
                });
            }
            let _ = this.update(cx, |_this, cx| cx.notify());
        })
        .detach();

        let show_onboarding = !config.app.onboarding_completed;
        let permission_statuses = permissions::check_all();
        let onboarding_perm_state =
            onboarding::PermissionState::from_statuses(&permission_statuses);
        Self::start_permission_polling(cx);

        Self {
            shared,
            active_pane: SettingsPane::General,
            sidebar_collapsed: false,
            recording_hotkey: false,
            recording_toggle_hotkey: false,
            openai_inputs: ProviderInputs {
                api_key: openai_api_key,
                base_url: openai_base_url,
            },
            groq_inputs: ProviderInputs {
                api_key: groq_api_key,
                base_url: groq_base_url,
            },
            cerebras_inputs: ProviderInputs {
                api_key: cerebras_api_key,
                base_url: cerebras_base_url,
            },
            fireworks_inputs: ProviderInputs {
                api_key: fireworks_api_key,
                base_url: fireworks_base_url,
            },
            elevenlabs_inputs: ProviderInputs {
                api_key: elevenlabs_api_key,
                base_url: elevenlabs_base_url,
            },
            expanded_provider: Some(0),
            apple_speech_search,
            expanded_style: Some(0),
            prompt_expanded: false,
            default_prompt,
            default_stt_search,
            default_llm_search,
            styles,
            last_fetched_openai_key: config.providers.openai.api_key.clone(),
            last_fetched_groq_key: config.providers.groq.api_key.clone(),
            last_fetched_cerebras_key: config.providers.cerebras.api_key.clone(),
            last_fetched_fireworks_key: config.providers.fireworks.api_key.clone(),
            last_fetched_elevenlabs_key: config.providers.elevenlabs.api_key.clone(),
            last_fetched_openai_base_url: config.providers.openai.base_url.clone(),
            last_fetched_groq_base_url: config.providers.groq.base_url.clone(),
            last_fetched_cerebras_base_url: config.providers.cerebras.base_url.clone(),
            last_fetched_fireworks_base_url: config.providers.fireworks.base_url.clone(),
            last_fetched_elevenlabs_base_url: config.providers.elevenlabs.base_url.clone(),
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

    fn create_style_inputs(
        entry: &Style,
        window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> (StyleInputs, Vec<Subscription>) {
        let name = cx.new(|cx| InputState::new(window, cx).default_value(&entry.name));
        let prompt = cx.new(|cx| {
            InputState::new(window, cx)
                .auto_grow(3, 12)
                .default_value(&entry.prompt)
        });
        let search = cx.new(|cx| InputState::new(window, cx));
        let stt_model_search = cx.new(|cx| InputState::new(window, cx));
        let llm_model_search = cx.new(|cx| InputState::new(window, cx));
        let subs = vec![
            cx.subscribe_in(&name, window, Self::on_input_change),
            cx.subscribe_in(&prompt, window, Self::on_input_change),
        ];
        (
            StyleInputs {
                name,
                apps: entry.apps.clone(),
                prompt,
                prompt_expanded: false,
                search,
                stt_model_search,
                llm_model_search,
            },
            subs,
        )
    }

    fn start_permission_polling(cx: &mut gpui::Context<Self>) {
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                let ok = this.update(cx, |view, cx| {
                    if view.refresh_permissions() {
                        cx.notify();
                    }
                    true
                });
                if ok.is_err() {
                    break;
                }
            }
        })
        .detach();
    }

    fn refresh_permissions(&mut self) -> bool {
        let next_statuses = permissions::check_all();
        let next_state = onboarding::PermissionState::from_statuses(&next_statuses);
        let statuses_changed = self.permission_statuses != next_statuses;
        let state_changed = self.onboarding_perm_state != next_state;
        let microphone_changed = self.onboarding_perm_state.microphone != next_state.microphone;

        if statuses_changed {
            self.permission_statuses = next_statuses;
        }
        if state_changed {
            self.onboarding_perm_state = next_state;
        }
        if microphone_changed {
            self.shared.refresh_input_devices();
        }

        statuses_changed || state_changed
    }

    fn on_input_change(
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

    fn schedule_autosave(&mut self, cx: &mut gpui::Context<Self>) {
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
        let new_openai_key = draft.providers.openai.api_key.clone();
        let new_groq_key = draft.providers.groq.api_key.clone();
        let new_cerebras_key = draft.providers.cerebras.api_key.clone();
        let new_fireworks_key = draft.providers.fireworks.api_key.clone();
        let new_elevenlabs_key = draft.providers.elevenlabs.api_key.clone();
        let new_openai_base_url = draft.providers.openai.base_url.clone();
        let new_groq_base_url = draft.providers.groq.base_url.clone();
        let new_cerebras_base_url = draft.providers.cerebras.base_url.clone();
        let new_fireworks_base_url = draft.providers.fireworks.base_url.clone();
        let new_elevenlabs_base_url = draft.providers.elevenlabs.base_url.clone();
        let providers_changed = new_openai_key != self.last_fetched_openai_key
            || new_groq_key != self.last_fetched_groq_key
            || new_cerebras_key != self.last_fetched_cerebras_key
            || new_fireworks_key != self.last_fetched_fireworks_key
            || new_elevenlabs_key != self.last_fetched_elevenlabs_key
            || new_openai_base_url != self.last_fetched_openai_base_url
            || new_groq_base_url != self.last_fetched_groq_base_url
            || new_cerebras_base_url != self.last_fetched_cerebras_base_url
            || new_fireworks_base_url != self.last_fetched_fireworks_base_url
            || new_elevenlabs_base_url != self.last_fetched_elevenlabs_base_url;
        let providers = draft.providers.clone();
        let _ = self.shared.update_config(move |config| *config = draft);
        if providers_changed {
            self.last_fetched_openai_key = new_openai_key;
            self.last_fetched_groq_key = new_groq_key;
            self.last_fetched_cerebras_key = new_cerebras_key;
            self.last_fetched_fireworks_key = new_fireworks_key;
            self.last_fetched_elevenlabs_key = new_elevenlabs_key;
            self.last_fetched_openai_base_url = new_openai_base_url;
            self.last_fetched_groq_base_url = new_groq_base_url;
            self.last_fetched_cerebras_base_url = new_cerebras_base_url;
            self.last_fetched_fireworks_base_url = new_fireworks_base_url;
            self.last_fetched_elevenlabs_base_url = new_elevenlabs_base_url;
            crate::model_catalog::fetch_all_models(&providers);

            let shared = self.shared.clone();
            cx.spawn(async move |this, cx| {
                cx.background_executor().timer(Duration::from_secs(3)).await;
                if crate::model_catalog::any_provider_verified() {
                    let _ = shared.update_config(|config| {
                        crate::model_catalog::apply_smart_defaults_initial(config);
                    });
                }
                let _ = this.update(cx, |_this, cx| cx.notify());
            })
            .detach();
        }
    }

    fn draft_from_inputs(&self, cx: &gpui::Context<Self>) -> GlideConfig {
        let mut config = self.shared.snapshot().config;

        config.providers.openai.api_key = self.openai_inputs.api_key.read(cx).value().to_string();
        config.providers.openai.base_url = self.openai_inputs.base_url.read(cx).value().to_string();
        config.providers.groq.api_key = self.groq_inputs.api_key.read(cx).value().to_string();
        config.providers.groq.base_url = self.groq_inputs.base_url.read(cx).value().to_string();
        config.providers.cerebras.api_key =
            self.cerebras_inputs.api_key.read(cx).value().to_string();
        config.providers.cerebras.base_url =
            self.cerebras_inputs.base_url.read(cx).value().to_string();
        config.providers.fireworks.api_key =
            self.fireworks_inputs.api_key.read(cx).value().to_string();
        config.providers.fireworks.base_url =
            self.fireworks_inputs.base_url.read(cx).value().to_string();
        config.providers.elevenlabs.api_key =
            self.elevenlabs_inputs.api_key.read(cx).value().to_string();
        config.providers.elevenlabs.base_url =
            self.elevenlabs_inputs.base_url.read(cx).value().to_string();

        config.dictation.system_prompt = self.default_prompt.read(cx).value().to_string();

        let existing_styles = config.dictation.styles.clone();
        config.dictation.styles = self
            .styles
            .iter()
            .enumerate()
            .map(|s| Style {
                name: s.1.name.read(cx).value().to_string(),
                apps: s.1.apps.clone(),
                prompt: s.1.prompt.read(cx).value().to_string(),
                stt: existing_styles.get(s.0).and_then(|style| style.stt.clone()),
                llm: existing_styles.get(s.0).and_then(|style| style.llm.clone()),
            })
            .collect();

        config
    }

    fn render_sidebar(
        &self,
        _window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl IntoElement {
        let collapsed = self.sidebar_collapsed;

        Sidebar::new(Side::Left).collapsed(collapsed).child(
            SidebarMenu::new()
                .child(
                    SidebarMenuItem::new("General")
                        .icon(Icon::new(IconName::Settings))
                        .active(self.active_pane == SettingsPane::General)
                        .on_click(cx.listener(|this, _, _window, cx| {
                            this.active_pane = SettingsPane::General;
                            cx.notify();
                        })),
                )
                .child(
                    SidebarMenuItem::new("Styles")
                        .icon(Icon::new(IconName::Palette))
                        .active(self.active_pane == SettingsPane::Styles)
                        .on_click(cx.listener(|this, _, _window, cx| {
                            this.active_pane = SettingsPane::Styles;
                            cx.notify();
                        })),
                )
                .child(
                    SidebarMenuItem::new("Providers")
                        .icon(Icon::new(IconName::Globe))
                        .active(self.active_pane == SettingsPane::Providers)
                        .on_click(cx.listener(|this, _, _window, cx| {
                            this.active_pane = SettingsPane::Providers;
                            cx.notify();
                        })),
                )
                .child(
                    SidebarMenuItem::new("Dictionary")
                        .icon(Icon::new(IconName::BookOpen))
                        .active(self.active_pane == SettingsPane::Dictionary)
                        .on_click(cx.listener(|this, _, _window, cx| {
                            this.active_pane = SettingsPane::Dictionary;
                            cx.notify();
                        })),
                ),
        )
    }

    fn render_content(
        &mut self,
        window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl IntoElement {
        let snapshot = self.shared.snapshot();

        div()
            .flex_1()
            .min_w_0()
            .overflow_hidden()
            .p_6()
            .id("content-scroll")
            .overflow_y_scroll()
            .bg(cx.theme().background)
            .child(match self.active_pane {
                SettingsPane::Providers => self
                    .render_providers_pane(window, cx, &snapshot)
                    .into_any_element(),
                SettingsPane::Styles => self.render_styles_pane(window, cx).into_any_element(),
                SettingsPane::General => self
                    .render_general_pane(window, cx, &snapshot)
                    .into_any_element(),
                SettingsPane::Dictionary => {
                    self.render_dictionary_pane(window, cx).into_any_element()
                }
            })
    }
}

impl Render for SettingsApp {
    fn render(
        &mut self,
        window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl IntoElement {
        if self.show_onboarding {
            return self
                .render_onboarding_overlay(window, cx)
                .into_any_element();
        }

        let snapshot = self.shared.snapshot();
        let mic_name = if snapshot.config.audio.device == "default" {
            "Default Microphone".to_string()
        } else {
            snapshot.config.audio.device.clone()
        };
        let devices: Vec<String> = if snapshot.input_devices.is_empty() {
            vec!["default".to_string()]
        } else {
            snapshot.input_devices.clone()
        };

        div()
            .flex()
            .size_full()
            .bg(cx.theme().background)
            .child(self.render_sidebar(window, cx))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .px_3()
                            .py_2()
                            .border_b_1()
                            .border_color(cx.theme().border)
                            .child(
                                SidebarToggleButton::left()
                                    .collapsed(self.sidebar_collapsed)
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.sidebar_collapsed = !this.sidebar_collapsed;
                                        cx.notify();
                                    })),
                            )
                            .child({
                                let shared_for_menu = self.shared.clone();
                                Button::new("top-bar-mic")
                                    .label(SharedString::from(mic_name))
                                    .ghost()
                                    .small()
                                    .compact()
                                    .dropdown_menu(move |menu, _, _| {
                                        let mut m = menu;
                                        for device in &devices {
                                            let d = device.clone();
                                            let shared = shared_for_menu.clone();
                                            m = m.item(
                                                PopupMenuItem::new(SharedString::from(d.clone()))
                                                    .on_click(move |_, _, _cx| {
                                                        let _ = shared.update_config(|config| {
                                                            config.audio.device = d.clone();
                                                        });
                                                    }),
                                            );
                                        }
                                        m
                                    })
                            }),
                    )
                    .child(self.render_content(window, cx)),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests;
