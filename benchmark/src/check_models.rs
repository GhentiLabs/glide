use std::collections::HashSet;

use anyhow::{Context, Result};

use glide::benchmark_support::{
    LLM_REMOTE_DEFAULTS, Provider, ProvidersConfig, STT_REMOTE_DEFAULTS, known_remote_llm_models,
    known_remote_stt_models,
};

/// Providers to verify, with the env var holding their API key and whether
/// their `/models` response authoritatively lists every live model. Fireworks
/// omits serverless models from `/models`, so absence there is reported but
/// not failed. ElevenLabs has no OpenAI-compatible listing and is not checked.
const CHECKS: &[(Provider, &str, bool)] = &[
    (Provider::Groq, "GROQ_API_KEY", true),
    (Provider::OpenAi, "OPENAI_API_KEY", true),
    (Provider::Cerebras, "CEREBRAS_API_KEY", true),
    (Provider::Fireworks, "FIREWORKS_API_KEY", false),
];

pub(super) fn run_check_models() -> Result<()> {
    let providers = ProvidersConfig::default();
    let mut failures = Vec::new();
    let mut checked = 0;

    for &(provider, key_var, authoritative) in CHECKS {
        let Ok(api_key) = std::env::var(key_var) else {
            println!("{}: skipped ({key_var} not set)", provider.label());
            continue;
        };

        let base_url = &providers.credentials_for(provider).base_url;
        let available = fetch_model_ids(base_url, &api_key)
            .with_context(|| format!("failed to list {} models", provider.label()))?;
        checked += 1;

        let missing = missing_models(&shipped_models(provider), &available);
        if missing.is_empty() {
            println!(
                "{}: all shipped models live ({} models listed)",
                provider.label(),
                available.len()
            );
        } else if authoritative {
            println!(
                "{}: MISSING from live catalog: {missing:?}",
                provider.label()
            );
            failures.push((provider.label(), missing));
        } else {
            println!(
                "{}: not in /models (non-authoritative listing): {missing:?}",
                provider.label()
            );
        }
    }

    anyhow::ensure!(
        checked > 0,
        "no provider API keys set; set at least one of GROQ_API_KEY, OPENAI_API_KEY, \
         CEREBRAS_API_KEY, FIREWORKS_API_KEY"
    );
    anyhow::ensure!(
        failures.is_empty(),
        "shipped models missing from provider catalogs: {failures:?}"
    );
    println!("model check: {checked} provider(s) verified");
    Ok(())
}

/// Every model id Glide ships for `provider`: smart defaults plus the
/// pre-fetch picker fallback.
pub(super) fn shipped_models(provider: Provider) -> Vec<String> {
    let defaults = STT_REMOTE_DEFAULTS
        .iter()
        .chain(LLM_REMOTE_DEFAULTS)
        .filter(|(candidate, _)| *candidate == provider)
        .map(|(_, model)| (*model).to_string());
    let known = known_remote_stt_models()
        .into_iter()
        .chain(known_remote_llm_models())
        .filter(|info| info.provider == provider.label())
        .map(|info| info.id);

    let mut models: Vec<String> = defaults.chain(known).collect();
    models.sort();
    models.dedup();
    models
}

pub(super) fn missing_models(shipped: &[String], available: &HashSet<String>) -> Vec<String> {
    shipped
        .iter()
        .filter(|model| !available.contains(*model))
        .cloned()
        .collect()
}

fn fetch_model_ids(base_url: &str, api_key: &str) -> Result<HashSet<String>> {
    #[derive(serde::Deserialize)]
    struct ModelsResponse {
        data: Vec<ModelsEntry>,
    }
    #[derive(serde::Deserialize)]
    struct ModelsEntry {
        id: String,
    }

    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let response = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?
        .get(&url)
        .bearer_auth(api_key)
        .send()?
        .error_for_status()?;

    let parsed: ModelsResponse = response.json()?;
    Ok(parsed.data.into_iter().map(|entry| entry.id).collect())
}
