use std::{
    sync::{Mutex, OnceLock},
    time::Duration,
};

use crate::config::{Provider, ProviderCredentials, ProvidersConfig};

use super::{
    catalog::{CACHED_LLM_MODELS, CACHED_STT_MODELS, model_info, model_info_with_display},
    types::ModelInfo,
    verification::set_remote_provider_verified,
};

#[derive(Default)]
struct DiscoveredModels {
    stt: Vec<ModelInfo>,
    llm: Vec<ModelInfo>,
}

impl DiscoveredModels {
    fn sort(&mut self) {
        self.stt
            .sort_by(|a, b| (&a.provider, &a.id).cmp(&(&b.provider, &b.id)));
        self.llm
            .sort_by(|a, b| (&a.provider, &a.id).cmp(&(&b.provider, &b.id)));
    }

    fn publish(self) {
        publish_model_cache(&CACHED_STT_MODELS, self.stt);
        publish_model_cache(&CACHED_LLM_MODELS, self.llm);
    }
}

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

#[derive(serde::Deserialize)]
pub(super) struct ElevenLabsModelsResponseEntry {
    pub(super) model_id: String,
    #[serde(default)]
    pub(super) name: Option<String>,
}

pub fn fetch_all_models(providers: &ProvidersConfig) {
    let remote_credentials = remote_credentials(providers);

    std::thread::spawn(move || {
        let client = build_models_client();
        let mut discovered = DiscoveredModels::default();

        fetch_openai_compatible_models(&client, &remote_credentials, &mut discovered);
        fetch_elevenlabs_models(&client, &remote_credentials, &mut discovered);

        discovered.sort();
        discovered.publish();
    });
}

fn remote_credentials(providers: &ProvidersConfig) -> Vec<(Provider, ProviderCredentials)> {
    providers
        .remote_credentials()
        .map(|(provider, credentials)| (provider, credentials.clone()))
        .collect()
}

fn build_models_client() -> reqwest::blocking::Client {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap_or_else(|_| reqwest::blocking::Client::new())
}

fn fetch_openai_compatible_models(
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

fn fetch_elevenlabs_models(
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
                eprintln!(
                    "[glide] ElevenLabs: failed to verify API key via {models_url}: {models_error:#}"
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
            eprintln!(
                "[glide] ElevenLabs: failed to parse model list from {models_url}: {error:#}"
            );
            Vec::new()
        })
}

pub(super) fn append_elevenlabs_scribe_models(
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

fn remote_model_is_stt(id_lower: &str) -> bool {
    id_lower.contains("whisper") || id_lower.contains("distil-whisper")
}

fn provider_supports_remote_stt(provider: Provider) -> bool {
    provider != Provider::Cerebras
}

pub(super) fn excluded_remote_llm_model(provider: Provider, id_lower: &str) -> bool {
    let excluded_by_family = id_lower.contains("embedding")
        || id_lower.contains("embed")
        || id_lower.contains("rerank")
        || id_lower.contains("tts")
        || id_lower.contains("dall-e")
        || id_lower.contains("flux")
        || id_lower.contains("stable-diffusion")
        || id_lower.contains("sdxl")
        || id_lower.contains("image")
        || id_lower.contains("moderation")
        || id_lower.starts_with("ft:")
        || id_lower.contains("realtime")
        || id_lower.contains("-audio-")
        || id_lower.contains("davinci")
        || id_lower.contains("babbage")
        || id_lower.contains("canary")
        || id_lower.contains("search")
        || id_lower.contains("similarity")
        || id_lower.starts_with("text-")
        || id_lower.starts_with("code-")
        || id_lower.contains("omni-")
        || id_lower.contains("orpheus");

    let excluded_openai_generation_model = provider == Provider::OpenAi
        && (matches!(id_lower, "sora-2" | "sora-2-pro")
            || id_lower.starts_with("gpt-image")
            || id_lower.starts_with("gpt-audio"));

    excluded_by_family || excluded_openai_generation_model
}

fn credentials_missing(credentials: &ProviderCredentials) -> bool {
    credentials.api_key.trim().is_empty() || credentials.base_url.trim().is_empty()
}

fn publish_model_cache(cache: &OnceLock<Mutex<Vec<ModelInfo>>>, models: Vec<ModelInfo>) {
    let cache = cache.get_or_init(|| Mutex::new(Vec::new()));
    *cache.lock().unwrap() = models;
}
