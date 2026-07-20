use std::sync::{Mutex, OnceLock};

use crate::{
    config::Provider,
    engines::model_assets::{self, ParakeetInstallState},
};

use super::{
    known_models::{known_remote_llm_models, known_remote_stt_models},
    types::ModelInfo,
    verification::provider_verified,
};

pub(super) static CACHED_STT_MODELS: OnceLock<Mutex<Vec<ModelInfo>>> = OnceLock::new();
pub(super) static CACHED_LLM_MODELS: OnceLock<Mutex<Vec<ModelInfo>>> = OnceLock::new();

pub fn cached_stt_models() -> Vec<ModelInfo> {
    cached_models(&CACHED_STT_MODELS, fallback_stt_models, local_stt_models)
}

pub fn cached_llm_models() -> Vec<ModelInfo> {
    cached_models(&CACHED_LLM_MODELS, fallback_llm_models, local_llm_models)
}

/// Whether the live-fetched catalog lists `model` for `provider`; `None` when
/// nothing has been fetched for the provider.
pub(super) fn stt_model_in_live_catalog(provider: Provider, model: &str) -> Option<bool> {
    live_catalog_contains(&CACHED_STT_MODELS, provider, model)
}

pub(super) fn llm_model_in_live_catalog(provider: Provider, model: &str) -> Option<bool> {
    live_catalog_contains(&CACHED_LLM_MODELS, provider, model)
}

fn live_catalog_contains(
    cache: &OnceLock<Mutex<Vec<ModelInfo>>>,
    provider: Provider,
    model: &str,
) -> Option<bool> {
    let label = provider.label();
    let locked = cache.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap();
    let mut saw_provider = false;
    for info in locked.iter().filter(|info| info.provider == label) {
        if info.id == model {
            return Some(true);
        }
        saw_provider = true;
    }
    saw_provider.then_some(false)
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
