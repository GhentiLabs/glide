use std::collections::HashSet;

use anyhow::{Context, Result};

use glide::benchmark_support::{
    LLM_REMOTE_DEFAULTS, ModelInfo, Provider, ProvidersConfig, STT_REMOTE_DEFAULTS,
    known_remote_llm_models, known_remote_stt_models,
};

struct ProviderCheck {
    provider: Provider,
    key_var: &'static str,
    /// Whether a shipped model of this kind missing from the listing proves
    /// decommission. Fireworks LLMs are verified via its control-plane
    /// catalog, but its STT models exist only as audio-API parameters with no
    /// listing anywhere. ElevenLabs has no compatible listing and is skipped.
    llm_authoritative: bool,
    stt_authoritative: bool,
}

const CHECKS: &[ProviderCheck] = &[
    ProviderCheck {
        provider: Provider::Groq,
        key_var: "GROQ_API_KEY",
        llm_authoritative: true,
        stt_authoritative: true,
    },
    ProviderCheck {
        provider: Provider::OpenAi,
        key_var: "OPENAI_API_KEY",
        llm_authoritative: true,
        stt_authoritative: true,
    },
    ProviderCheck {
        provider: Provider::Cerebras,
        key_var: "CEREBRAS_API_KEY",
        llm_authoritative: true,
        stt_authoritative: true,
    },
    ProviderCheck {
        provider: Provider::Fireworks,
        key_var: "FIREWORKS_API_KEY",
        llm_authoritative: true,
        stt_authoritative: false,
    },
];

const FIREWORKS_CATALOG_URL: &str = "https://api.fireworks.ai/v1/accounts/fireworks/models";

pub(super) fn run_check_models() -> Result<()> {
    let providers = ProvidersConfig::default();
    let mut failures = Vec::new();
    let mut checked = 0;

    for check in CHECKS {
        let label = check.provider.label();
        let Ok(api_key) = std::env::var(check.key_var) else {
            println!("{label}: skipped ({} not set)", check.key_var);
            continue;
        };

        let available = fetch_available_models(check.provider, &providers, &api_key)
            .with_context(|| format!("failed to list {label} models"))?;
        checked += 1;

        let kinds = [
            (
                "LLM",
                shipped_llm_models(check.provider),
                check.llm_authoritative,
            ),
            (
                "STT",
                shipped_stt_models(check.provider),
                check.stt_authoritative,
            ),
        ];
        for (kind, shipped, authoritative) in kinds {
            if shipped.is_empty() {
                continue;
            }
            let missing = missing_models(&shipped, &available);
            if missing.is_empty() {
                println!("{label} {kind}: all {} shipped models live", shipped.len());
            } else if authoritative {
                println!("{label} {kind}: MISSING from live catalog: {missing:?}");
                failures.push((label, kind, missing));
            } else {
                println!("{label} {kind}: not listed (unverifiable kind): {missing:?}");
            }
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

pub(super) fn shipped_llm_models(provider: Provider) -> Vec<String> {
    shipped_for(provider, LLM_REMOTE_DEFAULTS, known_remote_llm_models())
}

pub(super) fn shipped_stt_models(provider: Provider) -> Vec<String> {
    shipped_for(provider, STT_REMOTE_DEFAULTS, known_remote_stt_models())
}

fn shipped_for(
    provider: Provider,
    defaults: &[(Provider, &str)],
    known: Vec<ModelInfo>,
) -> Vec<String> {
    let defaults = defaults
        .iter()
        .filter(|(candidate, _)| *candidate == provider)
        .map(|(_, model)| (*model).to_string());
    let known = known
        .into_iter()
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

fn fetch_available_models(
    provider: Provider,
    providers: &ProvidersConfig,
    api_key: &str,
) -> Result<HashSet<String>> {
    match provider {
        Provider::Fireworks => fetch_fireworks_catalog(api_key),
        _ => fetch_openai_models(&providers.credentials_for(provider).base_url, api_key),
    }
}

fn fetch_openai_models(base_url: &str, api_key: &str) -> Result<HashSet<String>> {
    #[derive(serde::Deserialize)]
    struct ModelsResponse {
        data: Vec<ModelsEntry>,
    }
    #[derive(serde::Deserialize)]
    struct ModelsEntry {
        id: String,
    }

    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let parsed: ModelsResponse = http_client()?
        .get(&url)
        .bearer_auth(api_key)
        .send()?
        .error_for_status()?
        .json()?;
    Ok(parsed.data.into_iter().map(|entry| entry.id).collect())
}

/// Fireworks' OpenAI-compatible `/models` omits serverless models, so shipped
/// ids are checked against the paginated control-plane catalog instead.
fn fetch_fireworks_catalog(api_key: &str) -> Result<HashSet<String>> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct CatalogResponse {
        #[serde(default)]
        models: Vec<CatalogEntry>,
        #[serde(default)]
        next_page_token: Option<String>,
    }
    #[derive(serde::Deserialize)]
    struct CatalogEntry {
        name: String,
    }

    let client = http_client()?;
    let mut names = HashSet::new();
    let mut page_token: Option<String> = None;
    for _ in 0..20 {
        let mut request = client
            .get(FIREWORKS_CATALOG_URL)
            .query(&[("pageSize", "200")])
            .bearer_auth(api_key);
        if let Some(token) = &page_token {
            request = request.query(&[("pageToken", token.as_str())]);
        }
        let parsed: CatalogResponse = request.send()?.error_for_status()?.json()?;
        names.extend(parsed.models.into_iter().map(|entry| entry.name));
        page_token = parsed.next_page_token.filter(|token| !token.is_empty());
        if page_token.is_none() {
            break;
        }
    }
    Ok(names)
}

fn http_client() -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?)
}
