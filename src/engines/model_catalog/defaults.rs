use crate::{
    config::{GlideConfig, ModelSelection, Provider},
    engines::model_assets::{self, ParakeetInstallState},
};

use super::{
    catalog::{llm_model_in_live_catalog, stt_model_in_live_catalog},
    known_models::{LLM_REMOTE_DEFAULTS, STT_REMOTE_DEFAULTS},
    verification::{any_provider_verified, provider_verified},
};

pub fn smart_stt_default() -> Option<ModelSelection> {
    first_verified_remote_default(STT_REMOTE_DEFAULTS, stt_model_in_live_catalog)
        .or_else(installed_parakeet_stt_default)
        .or_else(installed_apple_speech_default)
}

pub fn smart_llm_default() -> Option<ModelSelection> {
    first_verified_remote_default(LLM_REMOTE_DEFAULTS, llm_model_in_live_catalog)
        .or_else(apple_foundation_llm_default)
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
        && let Some(smart) = smart_llm_default()
    {
        config.dictation.llm = Some(smart);
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
            remote_selection_available(selection, stt_model_in_live_catalog)
        }
        Provider::Cerebras => false,
        Provider::AppleLocal => apple_speech_selection_available(&selection.model),
        Provider::Parakeet => parakeet_selection_available(&selection.model),
    }
}

fn llm_selection_available(selection: &ModelSelection) -> bool {
    match selection.provider {
        Provider::OpenAi | Provider::Groq | Provider::Cerebras | Provider::Fireworks => {
            remote_selection_available(selection, llm_model_in_live_catalog)
        }
        Provider::ElevenLabs => false,
        Provider::AppleLocal => {
            model_assets::resolve_apple_foundation_model_id(&selection.model).is_some()
        }
        Provider::Parakeet => false,
    }
}

/// Available unless the provider's fetched catalog positively lacks the model.
fn remote_selection_available(
    selection: &ModelSelection,
    in_live_catalog: fn(Provider, &str) -> Option<bool>,
) -> bool {
    provider_verified(selection.provider)
        && in_live_catalog(selection.provider, &selection.model) != Some(false)
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

fn first_verified_remote_default(
    candidates: &[(Provider, &str)],
    in_live_catalog: fn(Provider, &str) -> Option<bool>,
) -> Option<ModelSelection> {
    candidates
        .iter()
        .filter(|(provider, _)| provider_verified(*provider))
        .find(|(provider, model)| in_live_catalog(*provider, model) != Some(false))
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
