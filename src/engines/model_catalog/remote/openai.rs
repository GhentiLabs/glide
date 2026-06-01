use crate::config::{Provider, ProviderCredentials};

use super::super::catalog::model_info;
use super::super::verification::set_remote_provider_verified;
use super::{DiscoveredModels, credentials_missing, excluded_remote_llm_model};

#[derive(Default)]
struct FireworksCatalogCoverage {
    saw_whisper_v3: bool,
    saw_whisper_turbo: bool,
    saw_gpt_oss_20b: bool,
    saw_gpt_oss_120b: bool,
}

impl FireworksCatalogCoverage {
    fn record(&mut self, id: &str) {
        self.saw_whisper_v3 |= id == "whisper-v3";
        self.saw_whisper_turbo |= id == "whisper-v3-turbo";
        self.saw_gpt_oss_20b |= id.ends_with("/gpt-oss-20b") || id == "gpt-oss-20b";
        self.saw_gpt_oss_120b |= id.ends_with("/gpt-oss-120b") || id == "gpt-oss-120b";
    }

    fn append_missing(&self, discovered: &mut DiscoveredModels) {
        if !self.saw_whisper_turbo {
            discovered
                .stt
                .push(model_info(Provider::Fireworks, "whisper-v3-turbo", false));
        }
        if !self.saw_whisper_v3 {
            discovered
                .stt
                .push(model_info(Provider::Fireworks, "whisper-v3", false));
        }
        if !self.saw_gpt_oss_20b {
            discovered.llm.push(model_info(
                Provider::Fireworks,
                "accounts/fireworks/models/gpt-oss-20b",
                false,
            ));
        }
        if !self.saw_gpt_oss_120b {
            discovered.llm.push(model_info(
                Provider::Fireworks,
                "accounts/fireworks/models/gpt-oss-120b",
                false,
            ));
        }
    }
}

#[derive(serde::Deserialize)]
struct ModelsResponse {
    data: Vec<ModelsResponseEntry>,
}

#[derive(serde::Deserialize)]
struct ModelsResponseEntry {
    id: String,
    #[serde(default)]
    active: Option<bool>,
}

pub(super) fn fetch_openai_compatible_models(
    client: &reqwest::blocking::Client,
    remote_credentials: &[(Provider, ProviderCredentials)],
    discovered: &mut DiscoveredModels,
) {
    for (provider, credentials) in remote_credentials
        .iter()
        .filter(|(provider, _)| *provider != Provider::ElevenLabs)
    {
        fetch_provider_models(client, *provider, credentials, discovered);
    }
}

fn fetch_provider_models(
    client: &reqwest::blocking::Client,
    provider: Provider,
    credentials: &ProviderCredentials,
    discovered: &mut DiscoveredModels,
) {
    if credentials_missing(credentials) {
        set_remote_provider_verified(provider, false);
        return;
    }

    let url = format!("{}/models", credentials.base_url.trim_end_matches('/'));
    let response = client
        .get(&url)
        .bearer_auth(&credentials.api_key)
        .send()
        .and_then(|response| response.json::<ModelsResponse>());

    match response {
        Ok(response) => {
            set_remote_provider_verified(provider, true);
            append_provider_models(provider, response, discovered);
        }
        Err(_) => set_remote_provider_verified(provider, false),
    }
}

fn append_provider_models(
    provider: Provider,
    response: ModelsResponse,
    discovered: &mut DiscoveredModels,
) {
    let mut fireworks = FireworksCatalogCoverage::default();

    for entry in response.data {
        if entry.active == Some(false) {
            continue;
        }

        if provider == Provider::Fireworks {
            fireworks.record(&entry.id);
        }

        let id_lower = entry.id.to_lowercase();
        let info = model_info(provider, entry.id.clone(), false);

        if remote_model_is_stt(&id_lower) {
            if provider_supports_remote_stt(provider) {
                discovered.stt.push(info);
            }
        } else if !excluded_remote_llm_model(provider, &id_lower) {
            discovered.llm.push(info);
        }
    }

    if provider == Provider::Fireworks {
        fireworks.append_missing(discovered);
    }
}

fn remote_model_is_stt(id_lower: &str) -> bool {
    id_lower.contains("whisper") || id_lower.contains("distil-whisper")
}

fn provider_supports_remote_stt(provider: Provider) -> bool {
    provider != Provider::Cerebras
}
