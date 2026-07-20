use std::{
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use crate::config::{Provider, ProviderCredentials, ProvidersConfig};

use super::{
    catalog::{CACHED_LLM_MODELS, CACHED_STT_MODELS},
    types::ModelInfo,
};

mod elevenlabs;
mod openai;

#[cfg(test)]
pub(super) use elevenlabs::{ElevenLabsModelsResponseEntry, append_elevenlabs_scribe_models};

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

static FETCH_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Monotonic count of completed fetches, bumped after `on_complete` so a
/// change guarantees the repaired config is already saved.
pub fn fetch_generation() -> u64 {
    FETCH_GENERATION.load(Ordering::Acquire)
}

/// Fetches provider model lists on a background thread; `on_complete` runs on
/// that thread after the catalog and verification state are published.
pub fn fetch_all_models(providers: &ProvidersConfig, on_complete: impl FnOnce() + Send + 'static) {
    let remote_credentials = remote_credentials(providers);

    std::thread::spawn(move || {
        // A client without its timeout would hang this thread indefinitely on
        // a dead connection; skip the fetch instead (providers stay
        // unverified) and still unblock completion-callback consumers.
        if let Ok(client) = build_models_client() {
            let mut discovered = DiscoveredModels::default();

            openai::fetch_openai_compatible_models(&client, &remote_credentials, &mut discovered);
            elevenlabs::fetch_elevenlabs_models(&client, &remote_credentials, &mut discovered);

            discovered.sort();
            discovered.publish();
        } else {
            eprintln!("model fetch skipped: failed to build HTTP client");
        }
        on_complete();
        FETCH_GENERATION.fetch_add(1, Ordering::AcqRel);
    });
}

fn remote_credentials(providers: &ProvidersConfig) -> Vec<(Provider, ProviderCredentials)> {
    providers
        .remote_credentials()
        .map(|(provider, credentials)| (provider, credentials.clone()))
        .collect()
}

fn build_models_client() -> reqwest::Result<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
}

pub(in crate::engines::model_catalog) fn excluded_remote_llm_model(
    provider: Provider,
    id_lower: &str,
) -> bool {
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
        || id_lower.contains("guard")
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
