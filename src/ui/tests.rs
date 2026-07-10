use super::*;
use std::sync::Arc;

use gpui::{AppContext, TestAppContext, VisualTestContext};

use crate::app::state::SharedAppState;
use crate::config::{GlideConfig, ModelSelection, Provider, Style};

fn test_shared_state() -> SharedState {
    Arc::new(SharedAppState::new(GlideConfig::default()))
}

fn init_and_create_view(cx: &mut TestAppContext) -> (Entity<SettingsApp>, VisualTestContext) {
    init_and_create_view_with(test_shared_state(), cx)
}

fn init_and_create_view_with(
    shared: SharedState,
    cx: &mut TestAppContext,
) -> (Entity<SettingsApp>, VisualTestContext) {
    cx.update(|app| {
        gpui_component::init(app);
    });

    let (view, cx) = cx.add_window_view(|window, cx| SettingsApp::new(shared, window, cx));
    let cx = cx.clone();
    (view, cx)
}

mod settings_state {
    use super::*;

    #[test]
    fn disable_llm_rewrite_persists_disabled_default() {
        let shared = test_shared_state();
        shared
            .update_config(|config| {
                config.dictation.llm = Some(ModelSelection {
                    provider: Provider::OpenAi,
                    model: "gpt-5.4-nano".to_string(),
                });
                config.dictation.smart_defaults_applied = false;
            })
            .unwrap();

        shared.update_config(helpers::disable_llm_rewrite).unwrap();

        let config = shared.snapshot().config;
        assert!(config.dictation.llm.is_none());
        assert!(config.dictation.smart_defaults_applied);
    }

    #[gpui::test]
    async fn settings_app_creation(cx: &mut TestAppContext) {
        let (view, cx) = init_and_create_view(cx);
        cx.read_entity(&view, |app, _| {
            assert_eq!(app.active_pane, SettingsPane::General);
            assert!(!app.save_pending);
        });
    }

    #[gpui::test]
    async fn default_input_values_match_config(cx: &mut TestAppContext) {
        let (view, cx) = init_and_create_view(cx);
        let defaults = GlideConfig::default();

        cx.read_entity(&view, |app, cx| {
            assert_eq!(
                app.provider_inputs_for(Provider::OpenAi)
                    .base_url
                    .read(cx)
                    .value()
                    .to_string(),
                defaults.providers.openai.base_url,
            );
            assert_eq!(
                app.provider_inputs_for(Provider::Cerebras)
                    .base_url
                    .read(cx)
                    .value()
                    .to_string(),
                defaults.providers.cerebras.base_url,
            );
            assert_eq!(
                app.provider_inputs_for(Provider::Fireworks)
                    .base_url
                    .read(cx)
                    .value()
                    .to_string(),
                defaults.providers.fireworks.base_url,
            );
            assert_eq!(
                app.provider_inputs_for(Provider::ElevenLabs)
                    .base_url
                    .read(cx)
                    .value()
                    .to_string(),
                defaults.providers.elevenlabs.base_url,
            );
        });
    }

    #[gpui::test]
    async fn removing_style_preserves_other_styles_model_overrides(cx: &mut TestAppContext) {
        let shared = test_shared_state();
        shared
            .update_config(|config| {
                config.dictation.styles = vec![
                    Style {
                        name: "A".to_string(),
                        apps: Vec::new(),
                        prompt: String::new(),
                        stt: None,
                        llm: None,
                    },
                    Style {
                        name: "B".to_string(),
                        apps: Vec::new(),
                        prompt: String::new(),
                        stt: Some(ModelSelection {
                            provider: Provider::ElevenLabs,
                            model: "scribe_v1".to_string(),
                        }),
                        llm: Some(ModelSelection {
                            provider: Provider::OpenAi,
                            model: "gpt-5.4-nano".to_string(),
                        }),
                    },
                ];
            })
            .unwrap();
        let (view, mut cx) = init_and_create_view_with(shared, cx);

        cx.update_entity(&view, |app, cx| {
            app.remove_style(0, cx);
            let styles = app.draft_from_inputs(cx).dictation.styles;
            assert_eq!(styles.len(), 1);
            assert_eq!(styles[0].name, "B");
            assert_eq!(
                styles[0].stt.as_ref().map(|sel| sel.model.as_str()),
                Some("scribe_v1"),
                "removing a style must not drop another style's STT override"
            );
            assert_eq!(
                styles[0].llm.as_ref().map(|sel| sel.model.as_str()),
                Some("gpt-5.4-nano"),
                "removing a style must not drop another style's LLM override"
            );
        });
    }

    #[gpui::test]
    async fn removing_unsaved_style_leaves_persisted_styles_intact(cx: &mut TestAppContext) {
        let shared = test_shared_state();
        shared
            .update_config(|config| {
                config.dictation.styles = vec![Style {
                    name: "A".to_string(),
                    apps: Vec::new(),
                    prompt: String::new(),
                    stt: Some(ModelSelection {
                        provider: Provider::ElevenLabs,
                        model: "scribe_v1".to_string(),
                    }),
                    llm: None,
                }];
            })
            .unwrap();
        let (view, mut cx) = init_and_create_view_with(shared.clone(), cx);

        cx.update(|window, cx| {
            view.update(cx, |app, cx| {
                let entry = Style {
                    name: "New".to_string(),
                    apps: Vec::new(),
                    prompt: String::new(),
                    stt: None,
                    llm: None,
                };
                let (inputs, subs) = SettingsApp::create_style_inputs(&entry, window, cx);
                app.styles.push(inputs);
                app._subscriptions.extend(subs);
            });
        });

        cx.update_entity(&view, |app, cx| {
            app.remove_style(1, cx);
            let styles = app.draft_from_inputs(cx).dictation.styles;
            assert_eq!(styles.len(), 1);
            assert_eq!(styles[0].name, "A");
            assert_eq!(
                styles[0].stt.as_ref().map(|sel| sel.model.as_str()),
                Some("scribe_v1")
            );
        });
        assert_eq!(shared.snapshot().config.dictation.styles.len(), 1);
    }

    #[gpui::test]
    async fn draft_from_inputs_matches_config(cx: &mut TestAppContext) {
        let (view, mut cx) = init_and_create_view(cx);
        let defaults = GlideConfig::default();

        cx.update_entity(&view, |app, cx| {
            let draft = app.draft_from_inputs(cx);
            assert_eq!(
                draft.providers.openai.base_url,
                defaults.providers.openai.base_url,
            );
            assert_eq!(
                draft.providers.cerebras.base_url,
                defaults.providers.cerebras.base_url,
            );
            assert_eq!(
                draft.dictation.system_prompt,
                defaults.dictation.system_prompt
            );
        });
    }
}

mod inputs_autosave {
    use super::*;

    #[gpui::test]
    async fn autosave_scheduling(cx: &mut TestAppContext) {
        let (view, mut cx) = init_and_create_view(cx);

        cx.update_entity(&view, |app, cx| {
            app.schedule_autosave(cx);
        });

        cx.read_entity(&view, |app, _| {
            assert!(app.save_pending);
        });

        cx.executor()
            .advance_clock(AUTOSAVE_DELAY + std::time::Duration::from_millis(100));
        cx.run_until_parked();

        cx.read_entity(&view, |app, _| {
            assert!(!app.save_pending);
        });
    }

    #[gpui::test]
    async fn input_change_subscription_schedules_autosave(cx: &mut TestAppContext) {
        let (view, mut cx) = init_and_create_view(cx);
        let input_entity = cx.read_entity(&view, |app, _| {
            app.provider_inputs_for(Provider::OpenAi).base_url.clone()
        });

        cx.read_entity(&view, |app, _| {
            assert!(!app.save_pending);
        });

        cx.update(|window, cx| {
            input_entity.update(cx, |state, cx| {
                use gpui::EntityInputHandler;
                state.replace_text_in_range(None, "x", window, cx);
            });
        });

        cx.run_until_parked();

        cx.read_entity(&view, |app, _| {
            assert!(
                app.save_pending,
                "subscription should have triggered autosave"
            );
        });

        cx.executor()
            .advance_clock(AUTOSAVE_DELAY + std::time::Duration::from_millis(100));
        cx.run_until_parked();

        cx.read_entity(&view, |app, _| {
            assert!(!app.save_pending, "autosave should have completed");
        });
    }
}
