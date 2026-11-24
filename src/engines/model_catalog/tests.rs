use super::*;
use crate::engines::model_assets::APPLE_FOUNDATION_MODEL_ID;
use std::sync::{Mutex, MutexGuard, OnceLock};

static PROVIDER_LOCK: Mutex<()> = Mutex::new(());

struct ProviderStateGuard<'a> {
    _lock: MutexGuard<'a, ()>,
}

impl Drop for ProviderStateGuard<'_> {
    fn drop(&mut self) {
        reset_provider_state();
    }
}

fn with_verified_providers(providers: &[Provider]) -> ProviderStateGuard<'static> {
    with_provider_state(providers, &[], &[])
}

fn with_provider_state(
    verified: &[Provider],
    live_stt: &[(Provider, &str)],
    live_llm: &[(Provider, &str)],
) -> ProviderStateGuard<'static> {
    let lock = PROVIDER_LOCK.lock().unwrap();
    reset_provider_state();
    for provider in verified {
        set_remote_provider_verified(*provider, true);
    }
    set_cached_models(&CACHED_STT_MODELS, live_stt);
    set_cached_models(&CACHED_LLM_MODELS, live_llm);
    ProviderStateGuard { _lock: lock }
}

fn set_cached_models(cache: &OnceLock<Mutex<Vec<ModelInfo>>>, models: &[(Provider, &str)]) {
    *cache.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap() = models
        .iter()
        .map(|(provider, id)| model_info(*provider, *id, false))
        .collect();
}

fn reset_provider_state() {
    let cache = PROVIDER_VERIFIED.get_or_init(|| Mutex::new([false; 5]));
    let mut locked = cache.lock().unwrap();
    *locked = [false; 5];
    drop(locked);
    set_cached_models(&CACHED_STT_MODELS, &[]);
    set_cached_models(&CACHED_LLM_MODELS, &[]);
    for model in model_assets::PARAKEET_MODELS {
        model_assets::set_parakeet_install_state_for_test(
            model.id,
            ParakeetInstallState::NotInstalled,
        );
    }
}

fn assert_selection(selection: &ModelSelection, provider: Provider, model: &str) {
    assert_eq!(selection.provider, provider);
    assert_eq!(selection.model, model);
}

mod verification {
    use super::*;

    #[test]
    fn remote_provider_state_is_tracked_per_provider() {
        for provider in Provider::REMOTE {
            let _state = with_verified_providers(&[provider]);
            assert!(
                provider_verified(provider),
                "{provider:?} should be verified"
            );
        }
    }
}

mod remote_models {
    use super::*;

    #[test]
    fn elevenlabs_model_discovery_keeps_known_scribe_models() {
        let cases = [
            (
                vec![ElevenLabsModelsResponseEntry {
                    model_id: "eleven_multilingual_v2".to_string(),
                    name: Some("Eleven Multilingual v2".to_string()),
                }],
                ("Scribe v2", "Scribe v1"),
            ),
            (
                vec![ElevenLabsModelsResponseEntry {
                    model_id: "scribe_v2".to_string(),
                    name: Some("Returned Scribe v2".to_string()),
                }],
                ("Returned Scribe v2", "Scribe v1"),
            ),
        ];

        for (entries, (expected_v2, expected_v1)) in cases {
            let mut models = Vec::new();
            append_elevenlabs_scribe_models(&mut models, entries);

            assert_eq!(models.len(), 2);
            assert!(models.iter().any(|model| {
                model.provider == "ElevenLabs"
                    && model.id == "scribe_v2"
                    && model.display_name == expected_v2
            }));
            assert!(models.iter().any(|model| {
                model.provider == "ElevenLabs"
                    && model.id == "scribe_v1"
                    && model.display_name == expected_v1
            }));
        }
    }

    #[test]
    fn openai_generation_models_are_excluded_from_llm_picker() {
        for id in [
            "sora-2",
            "sora-2-pro",
            "gpt-image-1",
            "gpt-image-1-mini",
            "gpt-audio",
            "gpt-audio-mini",
        ] {
            assert!(excluded_remote_llm_model(Provider::OpenAi, id), "{id}");
        }

        assert!(!excluded_remote_llm_model(Provider::OpenAi, "gpt-5.4-nano"));
        assert!(!excluded_remote_llm_model(Provider::Groq, "sora-2"));
    }

    #[test]
    fn guard_classifier_models_are_excluded_from_llm_picker() {
        for id in [
            "meta-llama/llama-prompt-guard-2-22m",
            "openai/gpt-oss-safeguard-20b",
            "meta-llama/llama-guard-4-12b",
        ] {
            assert!(excluded_remote_llm_model(Provider::Groq, id), "{id}");
        }

        assert!(!excluded_remote_llm_model(
            Provider::Groq,
            "llama-3.3-70b-versatile"
        ));
        assert!(!excluded_remote_llm_model(
            Provider::Groq,
            "openai/gpt-oss-20b"
        ));
    }
}

mod smart_defaults {
    use super::*;

    #[test]
    fn stt_default_uses_first_available_provider_by_priority() {
        let cases = [
            (&[][..], Provider::AppleLocal, "speechanalyzer-en_US"),
            (&[Provider::OpenAi][..], Provider::OpenAi, "whisper-1"),
            (
                &[Provider::Fireworks][..],
                Provider::Fireworks,
                "whisper-v3-turbo",
            ),
            (
                &[Provider::ElevenLabs][..],
                Provider::ElevenLabs,
                "scribe_v2",
            ),
            (
                &[Provider::Groq][..],
                Provider::Groq,
                "whisper-large-v3-turbo",
            ),
            (
                &[Provider::OpenAi, Provider::Groq][..],
                Provider::Groq,
                "whisper-large-v3-turbo",
            ),
        ];

        for (verified, expected_provider, expected_model) in cases {
            let _state = with_verified_providers(verified);
            let selection = smart_stt_default().unwrap();
            assert_selection(&selection, expected_provider, expected_model);
        }
    }

    #[test]
    fn llm_default_uses_first_available_provider_by_priority() {
        let cases = [
            (&[][..], Provider::AppleLocal, APPLE_FOUNDATION_MODEL_ID),
            (&[Provider::OpenAi][..], Provider::OpenAi, "gpt-5.4-nano"),
            (
                &[Provider::Fireworks][..],
                Provider::Fireworks,
                "accounts/fireworks/models/gpt-oss-20b",
            ),
            (
                &[Provider::Cerebras][..],
                Provider::Cerebras,
                "gpt-oss-120b",
            ),
            (
                &[Provider::Groq][..],
                Provider::Groq,
                "llama-3.3-70b-versatile",
            ),
            (
                &[Provider::OpenAi, Provider::Groq][..],
                Provider::Groq,
                "llama-3.3-70b-versatile",
            ),
        ];

        for (verified, expected_provider, expected_model) in cases {
            let _state = with_verified_providers(verified);
            let selection = smart_llm_default().unwrap();
            assert_selection(&selection, expected_provider, expected_model);
        }
    }

    #[test]
    fn apply_smart_defaults_repairs_unavailable_defaults_after_initial_run() {
        let cases = [
            (&[][..], Provider::AppleLocal, "speechanalyzer-en_US"),
            (
                &[Provider::Groq][..],
                Provider::Groq,
                "whisper-large-v3-turbo",
            ),
        ];

        for (verified, expected_provider, expected_model) in cases {
            let _state = with_verified_providers(verified);
            let mut config = GlideConfig::default();
            config.dictation.smart_defaults_applied = true;

            apply_smart_defaults(&mut config);

            assert_selection(&config.dictation.stt, expected_provider, expected_model);
            assert!(config.dictation.llm.is_none());
        }
    }

    #[test]
    fn apply_smart_defaults_keeps_verified_openai_stt_default() {
        let _state = with_verified_providers(&[Provider::OpenAi]);
        let mut config = GlideConfig::default();
        config.dictation.smart_defaults_applied = true;

        apply_smart_defaults(&mut config);

        assert_selection(&config.dictation.stt, Provider::OpenAi, "whisper-1");
        assert!(config.dictation.llm.is_none());
    }

    #[test]
    fn apply_smart_defaults_enables_llm_once() {
        let _state = with_verified_providers(&[Provider::Groq]);
        let mut config = GlideConfig::default();

        apply_smart_defaults(&mut config);

        assert_selection(
            &config.dictation.stt,
            Provider::Groq,
            "whisper-large-v3-turbo",
        );
        assert_selection(
            config.dictation.llm.as_ref().unwrap(),
            Provider::Groq,
            "llama-3.3-70b-versatile",
        );
        assert!(config.dictation.smart_defaults_applied);

        config.dictation.llm = None;
        apply_smart_defaults(&mut config);
        assert!(config.dictation.llm.is_none());
    }

    #[test]
    fn apply_smart_defaults_uses_verified_openai_llm_on_first_run() {
        let _state = with_verified_providers(&[Provider::OpenAi]);
        let mut config = GlideConfig::default();

        apply_smart_defaults(&mut config);

        assert_selection(&config.dictation.stt, Provider::OpenAi, "whisper-1");
        assert_selection(
            config.dictation.llm.as_ref().unwrap(),
            Provider::OpenAi,
            "gpt-5.4-nano",
        );
    }

    #[test]
    fn apply_smart_defaults_repairs_unverified_llm_provider() {
        let _state = with_verified_providers(&[Provider::Groq]);
        let mut config = GlideConfig::default();
        config.dictation.llm = Some(ModelSelection {
            provider: Provider::OpenAi,
            model: "gpt-4o".to_string(),
        });

        apply_smart_defaults(&mut config);

        assert_selection(
            config.dictation.llm.as_ref().unwrap(),
            Provider::Groq,
            "llama-3.3-70b-versatile",
        );
    }

    #[test]
    fn apply_smart_defaults_repairs_llm_model_missing_from_live_catalog() {
        let _state = with_provider_state(
            &[Provider::Groq],
            &[],
            &[
                (Provider::Groq, "llama-3.3-70b-versatile"),
                (Provider::Groq, "openai/gpt-oss-20b"),
            ],
        );
        let mut config = GlideConfig::default();
        config.dictation.smart_defaults_applied = true;
        config.dictation.llm = Some(ModelSelection {
            provider: Provider::Groq,
            model: "meta-llama/llama-4-scout-17b-16e-instruct".to_string(),
        });

        apply_smart_defaults(&mut config);

        assert_selection(
            config.dictation.llm.as_ref().unwrap(),
            Provider::Groq,
            "llama-3.3-70b-versatile",
        );
    }

    #[test]
    fn apply_smart_defaults_keeps_llm_selection_without_live_catalog() {
        // No Groq entries in the cache means no basis to invalidate the selection.
        let cases: [&[(Provider, &str)]; 2] = [&[], &[(Provider::OpenAi, "gpt-5.4-nano")]];

        for live_llm in cases {
            let _state = with_provider_state(&[Provider::Groq, Provider::OpenAi], &[], live_llm);
            let mut config = GlideConfig::default();
            config.dictation.smart_defaults_applied = true;
            config.dictation.llm = Some(ModelSelection {
                provider: Provider::Groq,
                model: "some-user-chosen-model".to_string(),
            });

            apply_smart_defaults(&mut config);

            assert_selection(
                config.dictation.llm.as_ref().unwrap(),
                Provider::Groq,
                "some-user-chosen-model",
            );
        }
    }

    #[test]
    fn llm_default_skips_candidates_missing_from_live_catalog() {
        let _state = with_provider_state(
            &[Provider::Groq, Provider::OpenAi],
            &[],
            &[
                (Provider::Groq, "llama-3.1-8b-instant"),
                (Provider::OpenAi, "gpt-5.4-nano"),
            ],
        );

        let selection = smart_llm_default().unwrap();

        assert_selection(&selection, Provider::OpenAi, "gpt-5.4-nano");
    }

    #[test]
    fn apply_smart_defaults_repairs_stt_model_missing_from_live_catalog() {
        let _state = with_provider_state(
            &[Provider::Groq],
            &[(Provider::Groq, "whisper-large-v3-turbo")],
            &[],
        );
        let mut config = GlideConfig::default();
        config.dictation.smart_defaults_applied = true;
        config.dictation.stt = ModelSelection {
            provider: Provider::Groq,
            model: "whisper-large-v2".to_string(),
        };

        apply_smart_defaults(&mut config);

        assert_selection(
            &config.dictation.stt,
            Provider::Groq,
            "whisper-large-v3-turbo",
        );
    }

    #[test]
    fn apply_smart_defaults_preserves_verified_selections() {
        let _state = with_verified_providers(&[Provider::OpenAi, Provider::Groq]);
        let mut config = GlideConfig::default();
        config.dictation.stt = ModelSelection {
            provider: Provider::OpenAi,
            model: "whisper-1".to_string(),
        };
        config.dictation.llm = Some(ModelSelection {
            provider: Provider::OpenAi,
            model: "gpt-4o".to_string(),
        });

        apply_smart_defaults(&mut config);

        assert_selection(&config.dictation.stt, Provider::OpenAi, "whisper-1");
        assert_selection(
            config.dictation.llm.as_ref().unwrap(),
            Provider::OpenAi,
            "gpt-4o",
        );
    }

    #[test]
    fn unavailable_apple_foundation_selection_falls_back_to_default() {
        let _state = with_verified_providers(&[]);
        let mut config = GlideConfig::default();
        config.dictation.llm = Some(ModelSelection {
            provider: Provider::AppleLocal,
            model: "unknown-model".to_string(),
        });

        apply_smart_defaults(&mut config);

        assert_selection(
            config.dictation.llm.as_ref().unwrap(),
            Provider::AppleLocal,
            APPLE_FOUNDATION_MODEL_ID,
        );
    }
}

mod model_lists {
    use super::*;

    #[test]
    fn fallback_stt_models_filter_by_verified_providers() {
        let cases = [
            (
                &[][..],
                vec!["Apple Intelligence"],
                vec!["speechanalyzer-en_US"],
                vec!["OpenAI", "Groq", "Fireworks", "ElevenLabs"],
            ),
            (
                &[Provider::Groq][..],
                vec!["Apple Intelligence", "Groq"],
                vec!["speechanalyzer-en_US", "whisper-large-v3-turbo"],
                vec!["OpenAI", "Fireworks", "ElevenLabs"],
            ),
        ];

        for (verified, expected_providers, expected_ids, absent_providers) in cases {
            let _state = with_verified_providers(verified);
            let models = fallback_stt_models();

            for provider in expected_providers {
                assert!(
                    models.iter().any(|model| model.provider == provider),
                    "missing provider {provider}"
                );
            }
            for id in expected_ids {
                assert!(models.iter().any(|model| model.id == id), "missing id {id}");
            }
            for provider in absent_providers {
                assert!(
                    models.iter().all(|model| model.provider != provider),
                    "unexpected provider {provider}"
                );
            }
        }
    }

    #[test]
    fn fallback_llm_models_filter_by_verified_providers() {
        let _state = with_verified_providers(&[]);
        let local_only = fallback_llm_models();
        assert!(
            local_only
                .iter()
                .any(|model| model.id == APPLE_FOUNDATION_MODEL_ID)
        );
        assert!(local_only.iter().all(|model| model.provider != "OpenAI"));

        drop(_state);
        let _state = with_verified_providers(&[Provider::OpenAi]);
        let with_openai = fallback_llm_models();

        assert!(with_openai.iter().any(|model| model.provider == "OpenAI"));
        assert!(
            with_openai
                .iter()
                .any(|model| model.provider == "Apple Intelligence")
        );
        assert!(with_openai.iter().any(|model| model.id == "gpt-5.4-nano"));
        assert!(
            with_openai
                .iter()
                .any(|model| model.id == APPLE_FOUNDATION_MODEL_ID)
        );
    }
}
