use std::sync::{Mutex, OnceLock};

use anyhow::{Context, Result};

#[cfg(not(test))]
use super::types::{AppleFoundationModel, AppleSpeechModel};
use super::{
    process::{helper_path, run_helper, write_temp_audio},
    transport::PersistentHelperClient,
    types::{
        AppleCapabilities, CleanupRequest, HelperResponse, SpeechModelRequest, TranscribeRequest,
    },
};

static CAPABILITIES: OnceLock<Mutex<Option<AppleCapabilities>>> = OnceLock::new();
static PERSISTENT_HELPER: OnceLock<Mutex<PersistentHelperClient>> = OnceLock::new();

pub fn cached_capabilities() -> AppleCapabilities {
    let cache = CAPABILITIES.get_or_init(|| Mutex::new(None));
    let mut locked = cache.lock().expect("Apple capabilities cache poisoned");
    if let Some(capabilities) = locked.clone() {
        return capabilities;
    }

    let capabilities = capabilities().unwrap_or_else(|error| AppleCapabilities {
        apple_speech_available: false,
        apple_speech_reason: error.to_string(),
        foundation_models_reason: error.to_string(),
    });
    *locked = Some(capabilities.clone());
    capabilities
}

pub fn invalidate_capabilities_cache() {
    if let Ok(mut locked) = CAPABILITIES.get_or_init(|| Mutex::new(None)).lock() {
        *locked = None;
    }
}

pub fn capabilities() -> Result<AppleCapabilities> {
    let response = run_helper("capabilities", None)?;
    Ok(AppleCapabilities {
        apple_speech_available: response.apple_speech_available,
        apple_speech_reason: response.apple_speech_reason,
        foundation_models_reason: response.foundation_models_reason,
    })
}

#[cfg(not(test))]
pub fn speech_models() -> Result<Vec<AppleSpeechModel>> {
    let response = run_helper("speech-models", None)?;
    Ok(response.speech_models)
}

#[cfg(not(test))]
pub fn foundation_models() -> Result<Vec<AppleFoundationModel>> {
    let response = run_helper("foundation-models", None)?;
    Ok(response.foundation_models)
}

pub fn release_speech_model(model_id: &str) -> Result<()> {
    let input = speech_model_request_json(model_id)?;
    run_helper("release-speech-model", Some(&input)).map(|_| ())
}

pub(crate) fn speech_model_request_json(model_id: &str) -> Result<Vec<u8>> {
    serde_json::to_vec(&SpeechModelRequest { model_id })
        .context("failed to encode Apple Speech model request")
}

pub(crate) fn transcribe(audio: &[u8], model_id: String) -> Result<String> {
    let audio_path = write_temp_audio(audio)?;
    let request = TranscribeRequest {
        audio_path: audio_path.to_string_lossy().to_string(),
        model_id,
    };
    let input = serde_json::to_vec(&request).context("failed to encode Apple Speech request")?;
    let result = run_persistent_helper("transcribe", &input).and_then(|response| {
        response
            .text
            .map(|text| text.trim().to_string())
            .context("Apple Speech helper did not return text")
    });
    std::fs::remove_file(&audio_path).ok();
    result
}

pub(crate) fn cleanup(model_id: &str, system_prompt: &str, user_prompt: &str) -> Result<String> {
    let request = CleanupRequest {
        model_id,
        system_prompt,
        user_prompt,
    };
    let input =
        serde_json::to_vec(&request).context("failed to encode Apple Foundation Models request")?;
    run_persistent_helper("cleanup", &input).and_then(|response| {
        response
            .text
            .map(|text| text.trim().to_string())
            .context("Apple Foundation Models helper did not return text")
    })
}

pub(crate) fn prewarm_foundation(model_id: &str, system_prompt: &str) -> Result<()> {
    let request = CleanupRequest {
        model_id,
        system_prompt,
        user_prompt: "",
    };
    let input = serde_json::to_vec(&request)
        .context("failed to encode Apple Foundation prewarm request")?;
    run_persistent_helper("prewarm-foundation", &input).map(|_| ())
}

fn run_persistent_helper(command: &str, input: &[u8]) -> Result<HelperResponse> {
    let helper = helper_path()?;
    let client = PERSISTENT_HELPER.get_or_init(|| Mutex::new(PersistentHelperClient::new(helper)));
    client
        .lock()
        .expect("Apple persistent helper client poisoned")
        .request(command, input)
}
