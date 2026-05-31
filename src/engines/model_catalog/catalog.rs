use std::sync::{Mutex, OnceLock};

use crate::{
    config::Provider,
    engines::model_assets::{self, ParakeetInstallState},
};

use super::{types::ModelInfo, verification::provider_verified};

pub(super) static CACHED_STT_MODELS: OnceLock<Mutex<Vec<ModelInfo>>> = OnceLock::new();
pub(super) static CACHED_LLM_MODELS: OnceLock<Mutex<Vec<ModelInfo>>> = OnceLock::new();

pub fn cached_stt_models() -> Vec<ModelInfo> {
    cached_models(&CACHED_STT_MODELS, fallback_stt_models, local_stt_models)
}

pub fn cached_llm_models() -> Vec<ModelInfo> {
    cached_models(&CACHED_LLM_MODELS, fallback_llm_models, local_llm_models)
}

pub(super) fn fallback_stt_models() -> Vec<ModelInfo> {
    let mut all = known_remote_stt_models();
    all.extend(local_stt_models());
    filter_models_by_verified_providers(all)
}

pub(super) fn fallback_llm_models() -> Vec<ModelInfo> {
    let mut all = known_remote_llm_models();
    all.extend(local_llm_models());
    filter_models_by_verified_providers(all)
}

fn cached_models(
    cache: &OnceLock<Mutex<Vec<ModelInfo>>>,
    fallback: fn() -> Vec<ModelInfo>,
    local: fn() -> Vec<ModelInfo>,
) -> Vec<ModelInfo> {
    let cache = cache.get_or_init(|| Mutex::new(Vec::new()));
    let locked = cache.lock().unwrap();
    if locked.is_empty() {
        fallback()
    } else {
        let mut models = locked.clone();
        models.extend(local());
        filter_models_by_verified_providers(models)
    }
}

// I don't like really doing these known models but it will keep it somewhat
// robust if the providers change their API spec for model retreival.
fn known_remote_stt_models() -> Vec<ModelInfo> {
    vec![
        model_info(Provider::OpenAi, "whisper-1", false),
        model_info(Provider::Groq, "whisper-large-v3", false),
        model_info(Provider::Groq, "whisper-large-v3-turbo", false),
        model_info(Provider::Fireworks, "whisper-v3-turbo", false),
        model_info(Provider::Fireworks, "whisper-v3", false),
        model_info_with_display(Provider::ElevenLabs, "scribe_v2", "Scribe v2", false),
        model_info_with_display(Provider::ElevenLabs, "scribe_v1", "Scribe v1", false),
    ]
}

fn known_remote_llm_models() -> Vec<ModelInfo> {
    vec![
        model_info(Provider::OpenAi, "gpt-5.4-nano", false),
        model_info(Provider::OpenAi, "gpt-4o-mini", false),
        model_info(Provider::OpenAi, "gpt-4o", false),
        model_info(Provider::OpenAi, "gpt-4-turbo", false),
        model_info(
            Provider::Groq,
            "meta-llama/llama-4-scout-17b-16e-instruct",
            false,
        ),
        model_info(Provider::Groq, "llama-3.3-70b-versatile", false),
        model_info(Provider::Groq, "llama-3.1-8b-instant", false),
        model_info(Provider::Groq, "mixtral-8x7b-32768", false),
        model_info(
            Provider::Fireworks,
            "accounts/fireworks/models/gpt-oss-20b",
            false,
        ),
        model_info(
            Provider::Fireworks,
            "accounts/fireworks/models/gpt-oss-120b",
            false,
        ),
        model_info(Provider::Cerebras, "gpt-oss-120b", false),
        model_info(Provider::Cerebras, "llama-4-scout-17b-16e-instruct", false),
    ]
}

fn local_stt_models() -> Vec<ModelInfo> {
    let mut models = apple_speech_model_infos();
    models.extend(installed_parakeet_model_infos());
    models
}

pub(super) fn local_llm_models() -> Vec<ModelInfo> {
    apple_foundation_model_infos()
}

fn installed_parakeet_model_infos() -> Vec<ModelInfo> {
    model_assets::parakeet_models_status()
        .into_iter()
        .filter_map(|status| {
            matches!(status.state, ParakeetInstallState::Installed { .. })
                .then(|| model_info(Provider::Parakeet, status.definition.id, true))
        })
        .collect()
}

fn apple_speech_model_infos() -> Vec<ModelInfo> {
    model_assets::apple_speech_models_status()
        .into_iter()
        .filter_map(|status| {
            (status.state == model_assets::AppleSpeechInstallState::Installed).then(|| {
                model_info_with_display(
                    Provider::AppleLocal,
                    status.definition.id,
                    status.definition.display_name,
                    true,
                )
            })
        })
        .collect()
}

fn apple_foundation_model_infos() -> Vec<ModelInfo> {
    model_assets::apple_foundation_models_status()
        .into_iter()
        .filter_map(|model| {
            model.available.then(|| {
                model_info_with_display(Provider::AppleLocal, model.id, model.display_name, true)
            })
        })
        .collect()
}

fn filter_models_by_verified_providers(models: Vec<ModelInfo>) -> Vec<ModelInfo> {
    models
        .into_iter()
        .filter(model_provider_is_visible)
        .collect()
}

fn model_provider_is_visible(model: &ModelInfo) -> bool {
    Provider::from_model_info_provider(&model.provider)
        .map(|provider| {
            if provider.is_local() {
                model.installed && provider_verified(provider)
            } else {
                provider_verified(provider)
            }
        })
        .unwrap_or(false)
}

pub(super) fn model_info(provider: Provider, id: impl Into<String>, installed: bool) -> ModelInfo {
    let id = id.into();
    model_info_with_display(provider, id.clone(), id, installed)
}

pub(super) fn model_info_with_display(
    provider: Provider,
    id: impl Into<String>,
    display_name: impl Into<String>,
    installed: bool,
) -> ModelInfo {
    ModelInfo {
        id: id.into(),
        display_name: display_name.into(),
        provider: provider.label().into(),
        logo: provider.logo().into(),
        installed,
    }
}
