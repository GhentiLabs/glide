#[cfg(not(test))]
use std::sync::{Mutex, OnceLock};

#[cfg(not(test))]
use super::types::APPLE_FOUNDATION_MODEL_DEFINITIONS;
#[cfg(test)]
use super::types::APPLE_FOUNDATION_MODEL_ID;
use super::types::AppleFoundationModelStatus;

#[cfg(not(test))]
static APPLE_FOUNDATION_MODELS: OnceLock<Mutex<Option<Vec<AppleFoundationModelStatus>>>> =
    OnceLock::new();

pub fn resolve_apple_foundation_model_id(model_id: &str) -> Option<String> {
    apple_foundation_models_status()
        .into_iter()
        .find(|model| model.id == model_id && model.available)
        .map(|model| model.id)
}

pub fn first_available_apple_foundation_model() -> Option<AppleFoundationModelStatus> {
    apple_foundation_models_status()
        .into_iter()
        .find(|model| model.available)
}

#[cfg(test)]
pub fn apple_foundation_models_status() -> Vec<AppleFoundationModelStatus> {
    vec![AppleFoundationModelStatus {
        id: APPLE_FOUNDATION_MODEL_ID.to_string(),
        display_name: "Apple Foundation Model".to_string(),
        model_name: "SystemLanguageModel.default".to_string(),
        available: true,
        reason: "available".to_string(),
    }]
}

#[cfg(not(test))]
pub fn apple_foundation_models_status() -> Vec<AppleFoundationModelStatus> {
    let cache = APPLE_FOUNDATION_MODELS.get_or_init(|| Mutex::new(None));
    if let Ok(mut cached) = cache.lock() {
        if let Some(models) = cached.clone() {
            return models;
        }

        let models = load_apple_foundation_models();
        *cached = Some(models.clone());
        models
    } else {
        unavailable_apple_foundation_models("Apple Foundation model cache unavailable".to_string())
    }
}

#[cfg(not(test))]
fn load_apple_foundation_models() -> Vec<AppleFoundationModelStatus> {
    match crate::engines::apple_bridge::foundation_models() {
        Ok(models) => models
            .into_iter()
            .map(|model| AppleFoundationModelStatus {
                id: model.id,
                display_name: model.display_name,
                model_name: model.model_name,
                available: model.available,
                reason: model.reason,
            })
            .collect::<Vec<_>>(),
        Err(error) => unavailable_apple_foundation_models(error.to_string()),
    }
}

#[cfg(not(test))]
fn unavailable_apple_foundation_models(reason: String) -> Vec<AppleFoundationModelStatus> {
    APPLE_FOUNDATION_MODEL_DEFINITIONS
        .iter()
        .map(
            |(id, display_name, model_name)| AppleFoundationModelStatus {
                id: (*id).to_string(),
                display_name: (*display_name).to_string(),
                model_name: (*model_name).to_string(),
                available: false,
                reason: reason.clone(),
            },
        )
        .collect()
}

#[cfg(test)]
pub(super) fn invalidate_apple_foundation_model_cache() {}

#[cfg(not(test))]
pub(super) fn invalidate_apple_foundation_model_cache() {
    if let Ok(mut cache) = APPLE_FOUNDATION_MODELS
        .get_or_init(|| Mutex::new(None))
        .lock()
    {
        *cache = None;
    }
}
