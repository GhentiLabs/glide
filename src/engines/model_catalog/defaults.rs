use crate::{
    config::{GlideConfig, ModelSelection, Provider},
    engines::model_assets::{self, ParakeetInstallState},
};

use super::verification::{any_provider_verified, provider_verified};

const STT_REMOTE_DEFAULTS: &[(Provider, &str)] = &[
    (Provider::Groq, "whisper-large-v3-turbo"),
    (Provider::OpenAi, "whisper-1"),
    (Provider::Fireworks, "whisper-v3-turbo"),
    (Provider::ElevenLabs, "scribe_v2"),
];

const LLM_REMOTE_DEFAULTS: &[(Provider, &str)] = &[
    (Provider::Groq, "llama-3.3-70b-versatile"),
    (Provider::OpenAi, "gpt-5.4-nano"),
    (Provider::Fireworks, "accounts/fireworks/models/gpt-oss-20b"),
    (Provider::Cerebras, "gpt-oss-120b"),
];

/// Models the provider has removed from its API; saved selections pointing at
/// one of these are repaired to the smart default by `apply_smart_defaults`.
const DECOMMISSIONED_MODELS: &[(Provider, &str)] = &[
    (Provider::Groq, "meta-llama/llama-4-scout-17b-16e-instruct"),
    (Provider::Groq, "mixtral-8x7b-32768"),
];

pub fn smart_stt_default() -> Option<ModelSelection> {
    first_verified_remote_default(STT_REMOTE_DEFAULTS)
        .or_else(installed_parakeet_stt_default)
        .or_else(installed_apple_speech_default)
}

pub fn smart_llm_default() -> Option<ModelSelection> {
    first_verified_remote_default(LLM_REMOTE_DEFAULTS).or_else(apple_foundation_llm_default)
}

/// Applies the best available defaults without overriding valid user selections.
///
/// On the first successful run, this also enables LLM rewrite if it is still unset.
/// Later runs only repair unavailable selections, so a user-disabled LLM stays disabled.
pub fn apply_smart_defaults(config: &mut GlideConfig) {
    if !any_provider_verified() {
        return;
    }

    if !stt_selection_available(&config.dictation.stt)
        && let Some(smart) = smart_stt_default()
    {
        config.dictation.stt = smart;
    }

    if let Some(ref llm) = config.dictation.llm
        && !llm_selection_available(llm)
    {
        config.dictation.llm = smart_llm_default();
    }

    if config.dictation.smart_defaults_applied {
        return;
    }

    if config.dictation.llm.is_none() {
        config.dictation.llm = smart_llm_default();
    }

    config.dictation.smart_defaults_applied = true;
}

fn stt_selection_available(selection: &ModelSelection) -> bool {
    match selection.provider {
        Provider::OpenAi | Provider::Groq | Provider::Fireworks | Provider::ElevenLabs => {
            provider_verified(selection.provider)
        }
        Provider::Cerebras => false,
        Provider::AppleLocal => apple_speech_selection_available(&selection.model),
        Provider::Parakeet => parakeet_selection_available(&selection.model),
    }
}

fn llm_selection_available(selection: &ModelSelection) -> bool {
    if DECOMMISSIONED_MODELS.contains(&(selection.provider, selection.model.as_str())) {
        return false;
    }
    match selection.provider {
        Provider::OpenAi | Provider::Groq | Provider::Cerebras | Provider::Fireworks => {
            provider_verified(selection.provider)
        }
        Provider::ElevenLabs => false,
        Provider::AppleLocal => {
            model_assets::resolve_apple_foundation_model_id(&selection.model).is_some()
        }
        Provider::Parakeet => false,
    }
}

fn apple_speech_selection_available(model: &str) -> bool {
    model_assets::apple_speech_locale_id(model).is_some()
        && model_assets::apple_speech_install_state(model)
            == model_assets::AppleSpeechInstallState::Installed
}

fn parakeet_selection_available(model: &str) -> bool {
    matches!(
        model_assets::parakeet_install_state(model),
        ParakeetInstallState::Installed { .. }
    )
}

fn first_verified_remote_default(candidates: &[(Provider, &str)]) -> Option<ModelSelection> {
    candidates
        .iter()
        .find(|(provider, _)| provider_verified(*provider))
        .map(|(provider, model)| model_selection(*provider, *model))
}

fn installed_parakeet_stt_default() -> Option<ModelSelection> {
    model_assets::parakeet_models_status()
        .into_iter()
        .find(|model| matches!(model.state, ParakeetInstallState::Installed { .. }))
        .map(|model| model_selection(Provider::Parakeet, model.definition.id))
}

fn installed_apple_speech_default() -> Option<ModelSelection> {
    model_assets::first_installed_apple_speech_model()
        .map(|model| model_selection(Provider::AppleLocal, model.definition.id))
}

fn apple_foundation_llm_default() -> Option<ModelSelection> {
    model_assets::first_available_apple_foundation_model()
        .map(|model| model_selection(Provider::AppleLocal, model.id))
}

fn model_selection(provider: Provider, model: impl Into<String>) -> ModelSelection {
    ModelSelection {
        provider,
        model: model.into(),
    }
}
