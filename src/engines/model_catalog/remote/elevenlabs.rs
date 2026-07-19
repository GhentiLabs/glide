use crate::config::{Provider, ProviderCredentials};

use super::super::catalog::model_info_with_display;
use super::super::types::ModelInfo;
use super::super::verification::set_remote_provider_verified;
use super::{DiscoveredModels, credentials_missing};

#[derive(serde::Deserialize)]
pub(in crate::engines::model_catalog) struct ElevenLabsModelsResponseEntry {
    pub(in crate::engines::model_catalog) model_id: String,
    #[serde(default)]
    pub(in crate::engines::model_catalog) name: Option<String>,
}

pub(super) fn fetch_elevenlabs_models(
    client: &reqwest::blocking::Client,
    remote_credentials: &[(Provider, ProviderCredentials)],
    discovered: &mut DiscoveredModels,
) {
    if let Some((_, credentials)) = remote_credentials
        .iter()
        .find(|(provider, _)| *provider == Provider::ElevenLabs)
    {
        fetch_elevenlabs_scribe_models(client, credentials, &mut discovered.stt);
    }
}

fn fetch_elevenlabs_scribe_models(
    client: &reqwest::blocking::Client,
    credentials: &ProviderCredentials,
    stt: &mut Vec<ModelInfo>,
) {
    if credentials_missing(credentials) {
        set_remote_provider_verified(Provider::ElevenLabs, false);
        return;
    }

    let api_key = credentials.api_key.trim();
    let base_url = credentials.base_url.trim_end_matches('/');
    let models_url = format!("{base_url}/models");
    let models_response = elevenlabs_get(client, &models_url, api_key);

    match models_response {
        Ok(response) => {
            set_remote_provider_verified(Provider::ElevenLabs, true);
            let discovered = parse_elevenlabs_models(response, &models_url);
            append_elevenlabs_scribe_models(stt, discovered);
        }
        Err(models_error) => {
            let user_url = format!("{base_url}/user");
            let user_verified = elevenlabs_get(client, &user_url, api_key).is_ok();

            set_remote_provider_verified(Provider::ElevenLabs, user_verified);
            if user_verified {
                append_elevenlabs_scribe_models(stt, Vec::new());
            } else {
                tracing::warn!(
                    "ElevenLabs: failed to verify API key via {models_url}: {models_error:#}"
                );
            }
        }
    }
}

fn elevenlabs_get(
    client: &reqwest::blocking::Client,
    url: &str,
    api_key: &str,
) -> reqwest::Result<reqwest::blocking::Response> {
    client
        .get(url)
        .header("xi-api-key", api_key)
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .and_then(|response| response.error_for_status())
}

fn parse_elevenlabs_models(
    response: reqwest::blocking::Response,
    models_url: &str,
) -> Vec<ElevenLabsModelsResponseEntry> {
    response
        .json::<Vec<ElevenLabsModelsResponseEntry>>()
        .unwrap_or_else(|error| {
            tracing::warn!("ElevenLabs: failed to parse model list from {models_url}: {error:#}");
            Vec::new()
        })
}

pub(in crate::engines::model_catalog) fn append_elevenlabs_scribe_models(
    stt: &mut Vec<ModelInfo>,
    entries: Vec<ElevenLabsModelsResponseEntry>,
) {
    let mut saw_scribe_v2 = false;
    let mut saw_scribe_v1 = false;

    for entry in entries {
        if !matches!(entry.model_id.as_str(), "scribe_v2" | "scribe_v1") {
            continue;
        }

        saw_scribe_v2 |= entry.model_id == "scribe_v2";
        saw_scribe_v1 |= entry.model_id == "scribe_v1";
        let display_name = entry.name.unwrap_or_else(|| {
            elevenlabs_scribe_display_name(&entry.model_id)
                .unwrap_or("ElevenLabs Scribe")
                .to_string()
        });
        stt.push(model_info_with_display(
            Provider::ElevenLabs,
            entry.model_id,
            display_name,
            false,
        ));
    }

    if !saw_scribe_v2 {
        stt.push(model_info_with_display(
            Provider::ElevenLabs,
            "scribe_v2",
            "Scribe v2",
            false,
        ));
    }
    if !saw_scribe_v1 {
        stt.push(model_info_with_display(
            Provider::ElevenLabs,
            "scribe_v1",
            "Scribe v1",
            false,
        ));
    }
}

fn elevenlabs_scribe_display_name(model_id: &str) -> Option<&'static str> {
    match model_id {
        "scribe_v2" => Some("Scribe v2"),
        "scribe_v1" => Some("Scribe v1"),
        _ => None,
    }
}
