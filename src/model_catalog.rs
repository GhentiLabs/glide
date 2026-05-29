use std::{
    sync::{Mutex, OnceLock},
    time::Duration,
};

use crate::config::{GlideConfig, ModelSelection, Provider, ProvidersConfig};
use crate::local_models::{self, LocalModelInstallState};

#[derive(Debug, Clone)]
pub struct ModelInfo {
    pub id: String,
    pub display_name: String,
    pub provider: String,
    pub logo: String,
    pub installed: bool,
}

static CACHED_STT_MODELS: OnceLock<Mutex<Vec<ModelInfo>>> = OnceLock::new();
static CACHED_LLM_MODELS: OnceLock<Mutex<Vec<ModelInfo>>> = OnceLock::new();
pub(crate) static PROVIDER_VERIFIED: OnceLock<Mutex<[bool; 5]>> = OnceLock::new();

fn set_remote_provider_verified(provider: Provider, verified: bool) {
    if let Some(index) = provider.remote_index() {
        let cache = PROVIDER_VERIFIED.get_or_init(|| Mutex::new([false; 5]));
        cache.lock().unwrap()[index] = verified;
    }
}

fn any_remote_provider_verified() -> bool {
    Provider::REMOTE.into_iter().any(provider_verified)
}

fn apple_speech_available() -> bool {
    #[cfg(test)]
    {
        local_models::first_installed_apple_speech_model().is_some()
    }
    #[cfg(not(test))]
    {
        local_models::first_installed_apple_speech_model().is_some()
    }
}

fn apple_foundation_available() -> bool {
    local_models::first_available_apple_foundation_model().is_some()
}

pub fn provider_verified(provider: Provider) -> bool {
    if let Some(index) = provider.remote_index() {
        let cache = PROVIDER_VERIFIED.get_or_init(|| Mutex::new([false; 5]));
        return cache.lock().unwrap()[index];
    }

    match provider {
        Provider::AppleLocal => apple_speech_available() || apple_foundation_available(),
        Provider::Parakeet => local_models::parakeet_models_status()
            .iter()
            .any(|model| matches!(model.state, LocalModelInstallState::Installed { .. })),
        Provider::OpenAi
        | Provider::Groq
        | Provider::Cerebras
        | Provider::Fireworks
        | Provider::ElevenLabs => false,
    }
}

pub fn any_provider_verified() -> bool {
    Provider::ALL.into_iter().any(provider_verified)
}

fn stt_selection_available(selection: &ModelSelection) -> bool {
    match selection.provider {
        Provider::OpenAi | Provider::Groq | Provider::Fireworks | Provider::ElevenLabs => {
            provider_verified(selection.provider)
        }
        Provider::Cerebras => false,
        Provider::AppleLocal => local_models::resolve_apple_speech_model_id(&selection.model)
            .map(|model_id| {
                local_models::apple_speech_install_state(&model_id)
                    == local_models::AppleSpeechInstallState::Installed
            })
            .unwrap_or(false),
        Provider::Parakeet => matches!(
            local_models::parakeet_install_state(&selection.model),
            LocalModelInstallState::Installed { .. }
        ),
    }
}

fn llm_selection_available(selection: &ModelSelection) -> bool {
    match selection.provider {
        Provider::OpenAi | Provider::Groq | Provider::Cerebras | Provider::Fireworks => {
            provider_verified(selection.provider)
        }
        Provider::ElevenLabs => false,
        Provider::AppleLocal => {
            local_models::resolve_apple_foundation_model_id(&selection.model).is_some()
        }
        Provider::Parakeet => false,
    }
}

pub fn smart_stt_default() -> Option<ModelSelection> {
    if provider_verified(Provider::Groq) {
        Some(ModelSelection {
            provider: Provider::Groq,
            model: "whisper-large-v3-turbo".to_string(),
        })
    } else if provider_verified(Provider::OpenAi) {
        Some(ModelSelection {
            provider: Provider::OpenAi,
            model: "whisper-1".to_string(),
        })
    } else if provider_verified(Provider::Fireworks) {
        Some(ModelSelection {
            provider: Provider::Fireworks,
            model: "whisper-v3-turbo".to_string(),
        })
    } else if provider_verified(Provider::ElevenLabs) {
        Some(ModelSelection {
            provider: Provider::ElevenLabs,
            model: "scribe_v2".to_string(),
        })
    } else if let Some(model) = local_models::parakeet_models_status()
        .into_iter()
        .find(|model| matches!(model.state, LocalModelInstallState::Installed { .. }))
    {
        Some(ModelSelection {
            provider: Provider::Parakeet,
            model: model.definition.id.to_string(),
        })
    } else if let Some(model) = local_models::first_installed_apple_speech_model() {
        Some(ModelSelection {
            provider: Provider::AppleLocal,
            model: model.definition.id,
        })
    } else {
        None
    }
}

pub fn smart_llm_default() -> Option<ModelSelection> {
    if provider_verified(Provider::Groq) {
        Some(ModelSelection {
            provider: Provider::Groq,
            model: "meta-llama/llama-4-scout-17b-16e-instruct".to_string(),
        })
    } else if provider_verified(Provider::OpenAi) {
        Some(ModelSelection {
            provider: Provider::OpenAi,
            model: "gpt-5.4-nano".to_string(),
        })
    } else if provider_verified(Provider::Fireworks) {
        Some(ModelSelection {
            provider: Provider::Fireworks,
            model: "accounts/fireworks/models/gpt-oss-20b".to_string(),
        })
    } else if provider_verified(Provider::Cerebras) {
        Some(ModelSelection {
            provider: Provider::Cerebras,
            model: "gpt-oss-120b".to_string(),
        })
    } else if let Some(model) = local_models::first_available_apple_foundation_model() {
        Some(ModelSelection {
            provider: Provider::AppleLocal,
            model: model.id,
        })
    } else {
        None
    }
}

pub fn apply_smart_defaults(config: &mut GlideConfig) {
    resolve_legacy_apple_speech_selections(config);

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
}

fn resolve_legacy_apple_speech_selections(config: &mut GlideConfig) {
    if config.dictation.stt.provider == Provider::AppleLocal
        && local_models::is_legacy_apple_speech_model(&config.dictation.stt.model)
        && let Some(model) = local_models::first_installed_apple_speech_model()
    {
        config.dictation.stt.model = model.definition.id;
    }

    for style in &mut config.dictation.styles {
        if let Some(stt) = &mut style.stt
            && stt.provider == Provider::AppleLocal
            && local_models::is_legacy_apple_speech_model(&stt.model)
            && let Some(model) = local_models::first_installed_apple_speech_model()
        {
            stt.model = model.definition.id;
        }
    }
}

/// Like `apply_smart_defaults` but also auto-enables LLM if currently disabled.
/// Full auto-enable only runs once; subsequent calls fall through to `apply_smart_defaults`.
pub fn apply_smart_defaults_initial(config: &mut GlideConfig) {
    if config.dictation.smart_defaults_applied {
        apply_smart_defaults(config);
        return;
    }

    apply_smart_defaults(config);

    if config.dictation.llm.is_none() {
        config.dictation.llm = smart_llm_default();
    }

    config.dictation.smart_defaults_applied = true;
}

fn fallback_stt_models() -> Vec<ModelInfo> {
    let mut all = vec![
        model_info(Provider::OpenAi, "whisper-1", false),
        model_info(Provider::Groq, "whisper-large-v3", false),
        model_info(Provider::Groq, "whisper-large-v3-turbo", false),
        model_info(Provider::Fireworks, "whisper-v3-turbo", false),
        model_info(Provider::Fireworks, "whisper-v3", false),
        model_info_with_display(Provider::ElevenLabs, "scribe_v2", "Scribe v2", false),
        model_info_with_display(Provider::ElevenLabs, "scribe_v1", "Scribe v1", false),
    ];
    all.extend(apple_speech_model_infos());
    all.extend(
        local_models::parakeet_models_status()
            .into_iter()
            .filter_map(|status| {
                let installed = matches!(status.state, LocalModelInstallState::Installed { .. });
                installed.then(|| model_info(Provider::Parakeet, status.definition.id, true))
            }),
    );
    filter_models_by_verified_providers(all)
}

fn fallback_llm_models() -> Vec<ModelInfo> {
    let all = vec![
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
    ];
    let mut all = all;
    all.extend(apple_foundation_model_infos());
    filter_models_by_verified_providers(all)
}

fn filter_models_by_verified_providers(models: Vec<ModelInfo>) -> Vec<ModelInfo> {
    if !any_remote_provider_verified()
        && !provider_verified(Provider::AppleLocal)
        && !provider_verified(Provider::Parakeet)
    {
        return models;
    }
    models
        .into_iter()
        .filter(|m| {
            Provider::from_model_info_provider(&m.provider)
                .map(|provider| {
                    if provider.is_local() {
                        m.installed && provider_verified(provider)
                    } else {
                        provider_verified(provider)
                    }
                })
                .unwrap_or(false)
        })
        .collect()
}

fn model_info(provider: Provider, id: impl Into<String>, installed: bool) -> ModelInfo {
    let id = id.into();
    model_info_with_display(provider, id.clone(), id, installed)
}

fn model_info_with_display(
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

pub fn cached_stt_models() -> Vec<ModelInfo> {
    let cache = CACHED_STT_MODELS.get_or_init(|| Mutex::new(Vec::new()));
    let locked = cache.lock().unwrap();
    if locked.is_empty() {
        fallback_stt_models()
    } else {
        let mut models = locked.clone();
        models.extend(local_stt_models());
        filter_models_by_verified_providers(models)
    }
}

pub fn cached_llm_models() -> Vec<ModelInfo> {
    let cache = CACHED_LLM_MODELS.get_or_init(|| Mutex::new(Vec::new()));
    let locked = cache.lock().unwrap();
    if locked.is_empty() {
        fallback_llm_models()
    } else {
        let mut models = locked.clone();
        models.extend(local_llm_models());
        filter_models_by_verified_providers(models)
    }
}

fn local_stt_models() -> Vec<ModelInfo> {
    let mut models = Vec::new();
    models.extend(apple_speech_model_infos());
    models.extend(
        local_models::parakeet_models_status()
            .into_iter()
            .filter_map(|status| {
                matches!(status.state, LocalModelInstallState::Installed { .. })
                    .then(|| model_info(Provider::Parakeet, status.definition.id, true))
            }),
    );
    models
}

fn apple_speech_model_infos() -> Vec<ModelInfo> {
    local_models::apple_speech_models_status()
        .into_iter()
        .filter_map(|status| {
            (status.state == local_models::AppleSpeechInstallState::Installed).then(|| {
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

fn local_llm_models() -> Vec<ModelInfo> {
    apple_foundation_model_infos()
}

fn apple_foundation_model_infos() -> Vec<ModelInfo> {
    local_models::apple_foundation_models_status()
        .into_iter()
        .filter_map(|model| {
            model.available.then(|| {
                model_info_with_display(Provider::AppleLocal, model.id, model.display_name, true)
            })
        })
        .collect()
}

fn excluded_remote_llm_model(provider: Provider, id_lower: &str) -> bool {
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
struct ElevenLabsModelsResponseEntry {
    model_id: String,
    #[serde(default)]
    name: Option<String>,
}

fn append_elevenlabs_scribe_models(
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

pub fn fetch_all_models(providers: &ProvidersConfig) {
    let remote_credentials = providers
        .remote_credentials()
        .map(|(provider, credentials)| (provider, credentials.clone()))
        .collect::<Vec<_>>();

    std::thread::spawn(move || {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap_or_else(|_| reqwest::blocking::Client::new());
        let mut stt = Vec::new();
        let mut llm = Vec::new();

        for (provider, creds) in remote_credentials
            .iter()
            .filter(|(provider, _)| *provider != Provider::ElevenLabs)
        {
            let provider = *provider;

            if creds.api_key.trim().is_empty() || creds.base_url.trim().is_empty() {
                set_remote_provider_verified(provider, false);
                continue;
            }

            let url = format!("{}/models", creds.base_url.trim_end_matches('/'));
            let resp = client
                .get(&url)
                .bearer_auth(&creds.api_key)
                .send()
                .and_then(|r| r.json::<ModelsResponse>());

            if let Ok(resp) = resp {
                set_remote_provider_verified(provider, true);
                let logo = provider.logo().to_string();
                let label = provider.label().to_string();
                let mut saw_fireworks_whisper_v3 = false;
                let mut saw_fireworks_whisper_turbo = false;
                let mut saw_fireworks_gpt_oss_20b = false;
                let mut saw_fireworks_gpt_oss_120b = false;
                for entry in resp.data {
                    if entry.active == Some(false) {
                        continue;
                    }

                    let id_lower = entry.id.to_lowercase();

                    let is_stt =
                        id_lower.contains("whisper") || id_lower.contains("distil-whisper");
                    if provider == Provider::Fireworks {
                        saw_fireworks_whisper_v3 |= entry.id == "whisper-v3";
                        saw_fireworks_whisper_turbo |= entry.id == "whisper-v3-turbo";
                        saw_fireworks_gpt_oss_20b |=
                            entry.id.ends_with("/gpt-oss-20b") || entry.id == "gpt-oss-20b";
                        saw_fireworks_gpt_oss_120b |=
                            entry.id.ends_with("/gpt-oss-120b") || entry.id == "gpt-oss-120b";
                    }

                    let info = ModelInfo {
                        id: entry.id.clone(),
                        display_name: entry.id,
                        provider: label.clone(),
                        logo: logo.clone(),
                        installed: false,
                    };

                    if is_stt {
                        if provider != Provider::Cerebras {
                            stt.push(info);
                        }
                    } else if !excluded_remote_llm_model(provider, &id_lower) {
                        llm.push(info);
                    }
                }
                if provider == Provider::Fireworks {
                    if !saw_fireworks_whisper_turbo {
                        stt.push(model_info(Provider::Fireworks, "whisper-v3-turbo", false));
                    }
                    if !saw_fireworks_whisper_v3 {
                        stt.push(model_info(Provider::Fireworks, "whisper-v3", false));
                    }
                    if !saw_fireworks_gpt_oss_20b {
                        llm.push(model_info(
                            Provider::Fireworks,
                            "accounts/fireworks/models/gpt-oss-20b",
                            false,
                        ));
                    }
                    if !saw_fireworks_gpt_oss_120b {
                        llm.push(model_info(
                            Provider::Fireworks,
                            "accounts/fireworks/models/gpt-oss-120b",
                            false,
                        ));
                    }
                }
            } else {
                set_remote_provider_verified(provider, false);
            }
        }

        if let Some((_, elevenlabs)) = remote_credentials
            .iter()
            .find(|(provider, _)| *provider == Provider::ElevenLabs)
        {
            let api_key = elevenlabs.api_key.trim();
            if api_key.is_empty() || elevenlabs.base_url.trim().is_empty() {
                set_remote_provider_verified(Provider::ElevenLabs, false);
            } else {
                let base_url = elevenlabs.base_url.trim_end_matches('/');
                let models_url = format!("{base_url}/models");
                let models_response = client
                    .get(&models_url)
                    .header("xi-api-key", api_key)
                    .header(reqwest::header::ACCEPT, "application/json")
                    .send()
                    .and_then(|r| r.error_for_status());

                match models_response {
                    Ok(response) => {
                        set_remote_provider_verified(Provider::ElevenLabs, true);
                        let discovered = response
                            .json::<Vec<ElevenLabsModelsResponseEntry>>()
                            .unwrap_or_else(|error| {
                                eprintln!(
                                    "[glide] ElevenLabs: failed to parse model list from {models_url}: {error:#}"
                                );
                                Vec::new()
                            });
                        append_elevenlabs_scribe_models(&mut stt, discovered);
                    }
                    Err(models_error) => {
                        let user_url = format!("{base_url}/user");
                        let user_verified = client
                            .get(&user_url)
                            .header("xi-api-key", api_key)
                            .header(reqwest::header::ACCEPT, "application/json")
                            .send()
                            .and_then(|r| r.error_for_status())
                            .is_ok();

                        set_remote_provider_verified(Provider::ElevenLabs, user_verified);
                        if user_verified {
                            append_elevenlabs_scribe_models(&mut stt, Vec::new());
                        } else {
                            eprintln!(
                                "[glide] ElevenLabs: failed to verify API key via {models_url}: {models_error:#}"
                            );
                        }
                    }
                }
            }
        }

        stt.sort_by(|a, b| (&a.provider, &a.id).cmp(&(&b.provider, &b.id)));
        llm.sort_by(|a, b| (&a.provider, &a.id).cmp(&(&b.provider, &b.id)));

        if !stt.is_empty() {
            let cache = CACHED_STT_MODELS.get_or_init(|| Mutex::new(Vec::new()));
            *cache.lock().unwrap() = stt;
        }
        if !llm.is_empty() {
            let cache = CACHED_LLM_MODELS.get_or_init(|| Mutex::new(Vec::new()));
            *cache.lock().unwrap() = llm;
        }
    });
}

#[cfg(test)]
mod tests;
