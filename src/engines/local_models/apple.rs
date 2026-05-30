use std::{
    collections::{HashMap, HashSet},
    io::{BufRead, BufReader, Read, Write},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, OnceLock},
    thread,
};

use anyhow::{Context, Result};

pub const APPLE_SPEECH_MODEL_ID: &str = "apple-speech-on-device";
pub const APPLE_SPEECH_MODEL_PREFIX: &str = "speechanalyzer-";
pub const APPLE_FOUNDATION_MODEL_ID: &str = "apple-foundation-default";

#[cfg(not(test))]
const APPLE_FOUNDATION_MODEL_DEFINITIONS: [(&str, &str, &str); 1] = [(
    APPLE_FOUNDATION_MODEL_ID,
    "Apple Foundation Model",
    "SystemLanguageModel.default",
)];

#[derive(Debug, Clone, PartialEq)]
pub enum AppleSpeechInstallState {
    NotInstalled,
    Downloading { progress: Option<f64> },
    Cancelling,
    Installed,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleSpeechModelDefinition {
    pub id: String,
    pub display_name: String,
    pub locale_id: String,
    pub asset_status: String,
    pub installed: bool,
    pub reserved: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AppleSpeechModelStatus {
    pub definition: AppleSpeechModelDefinition,
    pub state: AppleSpeechInstallState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleFoundationModelStatus {
    pub id: String,
    pub display_name: String,
    pub model_name: String,
    pub available: bool,
    pub reason: String,
}

static APPLE_SPEECH_MODELS: OnceLock<Mutex<Option<Vec<AppleSpeechModelDefinition>>>> =
    OnceLock::new();
static APPLE_SPEECH_MODELS_UNAVAILABLE_REASON: OnceLock<Mutex<Option<String>>> = OnceLock::new();
static APPLE_FOUNDATION_MODELS: OnceLock<Mutex<Option<Vec<AppleFoundationModelStatus>>>> =
    OnceLock::new();
static APPLE_SPEECH_DOWNLOADS: OnceLock<Mutex<HashMap<String, AppleSpeechInstallState>>> =
    OnceLock::new();
static APPLE_SPEECH_DOWNLOAD_CANCELLATIONS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
type AppleSpeechDownloadChild = Arc<Mutex<Option<Child>>>;
static APPLE_SPEECH_DOWNLOAD_CHILDREN: OnceLock<Mutex<HashMap<String, AppleSpeechDownloadChild>>> =
    OnceLock::new();

#[cfg(test)]
pub fn apple_speech_model_id(locale_id: &str) -> String {
    format!("{APPLE_SPEECH_MODEL_PREFIX}{locale_id}")
}

pub fn apple_speech_locale_id(model_id: &str) -> Option<&str> {
    model_id
        .strip_prefix(APPLE_SPEECH_MODEL_PREFIX)
        .filter(|locale| !locale.trim().is_empty())
}

pub fn is_legacy_apple_speech_model(model_id: &str) -> bool {
    model_id == APPLE_SPEECH_MODEL_ID
}

pub fn resolve_apple_speech_model_id(model_id: &str) -> Option<String> {
    if !is_legacy_apple_speech_model(model_id) {
        return Some(model_id.to_string()).filter(|id| apple_speech_locale_id(id).is_some());
    }

    first_installed_apple_speech_model().map(|model| model.definition.id)
}

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

pub fn apple_foundation_models_status() -> Vec<AppleFoundationModelStatus> {
    apple_foundation_model_statuses()
}

pub fn first_installed_apple_speech_model() -> Option<AppleSpeechModelStatus> {
    apple_speech_models_status()
        .into_iter()
        .find(|model| model.state == AppleSpeechInstallState::Installed)
}

pub fn apple_speech_models_status() -> Vec<AppleSpeechModelStatus> {
    apple_speech_model_definitions()
        .into_iter()
        .map(|definition| {
            let state = apple_speech_install_state_for_definition(&definition);
            AppleSpeechModelStatus { definition, state }
        })
        .collect()
}

pub fn apple_speech_models_unavailable_reason() -> Option<String> {
    APPLE_SPEECH_MODELS_UNAVAILABLE_REASON
        .get_or_init(|| Mutex::new(None))
        .lock()
        .ok()
        .and_then(|reason| reason.clone())
}

pub fn refresh_apple_local_models() {
    invalidate_apple_speech_model_cache();
    invalidate_apple_foundation_model_cache();
    crate::engines::apple_helper::invalidate_capabilities_cache();
}

pub fn apple_speech_install_state(id: &str) -> AppleSpeechInstallState {
    if let Some(state) = apple_speech_download_state(id) {
        return state;
    }

    apple_speech_model_definitions()
        .into_iter()
        .find(|definition| definition.id == id)
        .map(|definition| apple_speech_install_state_for_definition(&definition))
        .unwrap_or(AppleSpeechInstallState::NotInstalled)
}

pub fn start_apple_speech_model_download(id: &str) -> Result<()> {
    let definition = apple_speech_model_definitions()
        .into_iter()
        .find(|definition| definition.id == id)
        .with_context(|| format!("unknown Apple Speech model: {id}"))?;

    if matches!(
        apple_speech_download_state(&definition.id),
        Some(AppleSpeechInstallState::Downloading { .. } | AppleSpeechInstallState::Cancelling)
    ) {
        return Ok(());
    }

    clear_apple_speech_download_cancellation(&definition.id);
    set_apple_speech_download_state(
        &definition.id,
        AppleSpeechInstallState::Downloading { progress: None },
    );

    let model_id = definition.id.clone();
    thread::spawn(move || {
        if let Err(error) = download_and_install_apple_speech_model(&model_id) {
            if is_apple_speech_download_cancelled(&model_id) {
                let _ = crate::engines::apple_helper::release_speech_model(&model_id);
                clear_apple_speech_download_state(&model_id);
            } else {
                set_apple_speech_download_state(
                    &model_id,
                    AppleSpeechInstallState::Failed(error.to_string()),
                );
            }
        } else {
            clear_apple_speech_download_state(&model_id);
        }
        clear_apple_speech_download_child(&model_id);
        clear_apple_speech_download_cancellation(&model_id);
        invalidate_apple_speech_model_cache();
    });

    Ok(())
}

pub fn cancel_apple_speech_model_download(id: &str) -> Result<()> {
    anyhow::ensure!(
        apple_speech_locale_id(id).is_some(),
        "unknown Apple Speech model: {id}"
    );

    match apple_speech_download_state(id) {
        Some(AppleSpeechInstallState::Downloading { .. }) => {
            mark_apple_speech_download_cancelled(id);
            set_apple_speech_download_state(id, AppleSpeechInstallState::Cancelling);
            kill_apple_speech_download_child(id);
        }
        Some(AppleSpeechInstallState::Cancelling) => {
            mark_apple_speech_download_cancelled(id);
            kill_apple_speech_download_child(id);
        }
        _ => {}
    }

    Ok(())
}

pub fn release_apple_speech_model(id: &str) -> Result<()> {
    if matches!(
        apple_speech_download_state(id),
        Some(AppleSpeechInstallState::Downloading { .. } | AppleSpeechInstallState::Cancelling)
    ) {
        cancel_apple_speech_model_download(id)?;
        return Ok(());
    }

    crate::engines::apple_helper::release_speech_model(id)?;
    clear_apple_speech_download_state(id);
    invalidate_apple_speech_model_cache();
    Ok(())
}

pub fn apple_speech_has_active_downloads() -> bool {
    apple_speech_models_status().iter().any(|status| {
        matches!(
            status.state,
            AppleSpeechInstallState::Downloading { .. } | AppleSpeechInstallState::Cancelling
        )
    })
}

fn apple_speech_install_state_for_definition(
    definition: &AppleSpeechModelDefinition,
) -> AppleSpeechInstallState {
    if let Some(state) = apple_speech_download_state(&definition.id) {
        return state;
    }

    if definition.reserved {
        AppleSpeechInstallState::Installed
    } else {
        AppleSpeechInstallState::NotInstalled
    }
}

#[cfg(test)]
fn apple_speech_model_definitions() -> Vec<AppleSpeechModelDefinition> {
    let mut models = vec![
        AppleSpeechModelDefinition {
            id: apple_speech_model_id("en_US"),
            display_name: "English (United States)".to_string(),
            locale_id: "en_US".to_string(),
            asset_status: "installed".to_string(),
            installed: true,
            reserved: true,
        },
        AppleSpeechModelDefinition {
            id: apple_speech_model_id("fr_FR"),
            display_name: "French (France)".to_string(),
            locale_id: "fr_FR".to_string(),
            asset_status: "supported".to_string(),
            installed: false,
            reserved: false,
        },
    ];

    if let Ok(id) = std::env::var("GLIDE_TEST_APPLE_SPEECH_CANCEL_MODEL_ID")
        && let Some(locale_id) = apple_speech_locale_id(&id)
        && !models.iter().any(|model| model.id == id)
    {
        let locale_id = locale_id.to_string();
        models.push(AppleSpeechModelDefinition {
            id,
            display_name: format!("Test locale {locale_id}"),
            locale_id,
            asset_status: "supported".to_string(),
            installed: false,
            reserved: false,
        });
    }

    models
}

#[cfg(not(test))]
fn apple_speech_model_definitions() -> Vec<AppleSpeechModelDefinition> {
    let cache = APPLE_SPEECH_MODELS.get_or_init(|| Mutex::new(None));
    if let Ok(mut cached) = cache.lock() {
        if let Some(models) = cached.clone() {
            return models;
        }

        let models = match crate::engines::apple_helper::speech_models() {
            Ok(models) => models
                .into_iter()
                .map(|model| AppleSpeechModelDefinition {
                    id: model.id,
                    display_name: model.display_name,
                    locale_id: model.locale_id,
                    asset_status: model.status,
                    installed: model.installed,
                    reserved: model.reserved,
                })
                .collect::<Vec<_>>(),
            Err(error) => {
                set_apple_speech_models_unavailable_reason(Some(error.to_string()));
                *cached = None;
                return Vec::new();
            }
        };

        if models.is_empty() {
            set_apple_speech_models_unavailable_reason(Some(
                "Apple Speech returned no supported locales".to_string(),
            ));
            *cached = None;
        } else {
            set_apple_speech_models_unavailable_reason(None);
            *cached = Some(models.clone());
        }
        models
    } else {
        Vec::new()
    }
}

fn invalidate_apple_speech_model_cache() {
    if let Ok(mut cache) = APPLE_SPEECH_MODELS.get_or_init(|| Mutex::new(None)).lock() {
        *cache = None;
    }
    set_apple_speech_models_unavailable_reason(None);
}

pub(super) fn set_apple_speech_models_unavailable_reason(reason: Option<String>) {
    if let Ok(mut locked) = APPLE_SPEECH_MODELS_UNAVAILABLE_REASON
        .get_or_init(|| Mutex::new(None))
        .lock()
    {
        *locked = reason;
    }
}

#[cfg(test)]
pub(super) fn apple_foundation_model_statuses() -> Vec<AppleFoundationModelStatus> {
    vec![AppleFoundationModelStatus {
        id: APPLE_FOUNDATION_MODEL_ID.to_string(),
        display_name: "Apple Foundation Model".to_string(),
        model_name: "SystemLanguageModel.default".to_string(),
        available: true,
        reason: "available".to_string(),
    }]
}

#[cfg(not(test))]
pub(super) fn apple_foundation_model_statuses() -> Vec<AppleFoundationModelStatus> {
    let cache = APPLE_FOUNDATION_MODELS.get_or_init(|| Mutex::new(None));
    if let Ok(mut cached) = cache.lock() {
        if let Some(models) = cached.clone() {
            return models;
        }

        let models = match crate::engines::apple_helper::foundation_models() {
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
        };
        *cached = Some(models.clone());
        models
    } else {
        unavailable_apple_foundation_models("Apple Foundation model cache unavailable".to_string())
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

fn invalidate_apple_foundation_model_cache() {
    if let Ok(mut cache) = APPLE_FOUNDATION_MODELS
        .get_or_init(|| Mutex::new(None))
        .lock()
    {
        *cache = None;
    }
}

fn download_and_install_apple_speech_model(id: &str) -> Result<()> {
    let helper = crate::engines::apple_helper::helper_path()?;
    let input = crate::engines::apple_helper::speech_model_request_json(id)?;
    let mut child = Command::new(&helper)
        .arg("install-speech-model")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to start Apple helper at {}", helper.display()))?;

    let mut stdin = child
        .stdin
        .take()
        .context("failed to open Apple helper stdin")?;
    stdin
        .write_all(&input)
        .context("failed to write Apple Speech install request")?;
    drop(stdin);

    let stdout = child
        .stdout
        .take()
        .context("failed to open Apple helper stdout")?;
    let mut stderr = child
        .stderr
        .take()
        .context("failed to open Apple helper stderr")?;
    let child_handle = Arc::new(Mutex::new(Some(child)));
    set_apple_speech_download_child(id, child_handle.clone());

    let mut saw_finished = false;
    let mut helper_error = None;
    for line in BufReader::new(stdout).lines() {
        let line = line.context("failed to read Apple Speech install progress")?;
        if line.trim().is_empty() {
            continue;
        }

        let progress = serde_json::from_str::<
            crate::engines::apple_helper::AppleSpeechInstallProgress,
        >(line.trim())
        .with_context(|| format!("failed to parse Apple Speech install progress: {line}"))?;

        if !progress.model_id.is_empty() && progress.model_id != id {
            continue;
        }

        if !progress.ok {
            helper_error = Some(
                progress
                    .error
                    .unwrap_or_else(|| "Apple Speech install failed".to_string()),
            );
            break;
        }

        if progress.event == "finished" {
            saw_finished = true;
            set_apple_speech_download_state(
                id,
                AppleSpeechInstallState::Downloading {
                    progress: Some(1.0),
                },
            );
        } else if progress.event == "progress" {
            let fraction = progress
                .fraction_completed
                .map(|value| value.clamp(0.0, 1.0))
                .or_else(|| {
                    let total = progress.total_unit_count?;
                    let completed = progress.completed_unit_count?;
                    (total > 0).then_some((completed as f64 / total as f64).clamp(0.0, 1.0))
                });
            set_apple_speech_download_state(
                id,
                AppleSpeechInstallState::Downloading { progress: fraction },
            );
        }
    }

    let mut child = child_handle
        .lock()
        .ok()
        .and_then(|mut locked| locked.take())
        .context("Apple Speech helper process handle was unavailable")?;
    let status = child.wait().context("failed to wait for Apple helper")?;
    let mut stderr_output = String::new();
    let _ = stderr.read_to_string(&mut stderr_output);
    if is_apple_speech_download_cancelled(id) {
        anyhow::bail!("download cancelled");
    }
    if !status.success() {
        anyhow::bail!(
            "{}",
            crate::engines::apple_helper::helper_failure_message(
                "install-speech-model",
                &status,
                &stderr_output
            )
        );
    }
    if let Some(error) = helper_error {
        anyhow::bail!("{error}");
    }
    anyhow::ensure!(
        status.success() && saw_finished,
        "Apple Speech install did not complete"
    );

    Ok(())
}

pub(super) fn apple_speech_download_state(id: &str) -> Option<AppleSpeechInstallState> {
    APPLE_SPEECH_DOWNLOADS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .ok()
        .and_then(|downloads| downloads.get(id).cloned())
}

pub(super) fn set_apple_speech_download_state(id: &str, state: AppleSpeechInstallState) {
    if let Ok(mut downloads) = APPLE_SPEECH_DOWNLOADS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
    {
        downloads.insert(id.to_string(), state);
    }
}

pub(super) fn clear_apple_speech_download_state(id: &str) {
    if let Ok(mut downloads) = APPLE_SPEECH_DOWNLOADS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
    {
        downloads.remove(id);
    }
}

pub(super) fn mark_apple_speech_download_cancelled(id: &str) {
    if let Ok(mut cancellations) = APPLE_SPEECH_DOWNLOAD_CANCELLATIONS
        .get_or_init(|| Mutex::new(HashSet::new()))
        .lock()
    {
        cancellations.insert(id.to_string());
    }
}

pub(super) fn clear_apple_speech_download_cancellation(id: &str) {
    if let Ok(mut cancellations) = APPLE_SPEECH_DOWNLOAD_CANCELLATIONS
        .get_or_init(|| Mutex::new(HashSet::new()))
        .lock()
    {
        cancellations.remove(id);
    }
}

pub(super) fn is_apple_speech_download_cancelled(id: &str) -> bool {
    APPLE_SPEECH_DOWNLOAD_CANCELLATIONS
        .get_or_init(|| Mutex::new(HashSet::new()))
        .lock()
        .map(|cancellations| cancellations.contains(id))
        .unwrap_or(false)
}

fn set_apple_speech_download_child(id: &str, child: AppleSpeechDownloadChild) {
    if let Ok(mut children) = APPLE_SPEECH_DOWNLOAD_CHILDREN
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
    {
        children.insert(id.to_string(), child);
    }
}

pub(super) fn clear_apple_speech_download_child(id: &str) {
    if let Ok(mut children) = APPLE_SPEECH_DOWNLOAD_CHILDREN
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
    {
        children.remove(id);
    }
}

fn kill_apple_speech_download_child(id: &str) {
    let child = APPLE_SPEECH_DOWNLOAD_CHILDREN
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .ok()
        .and_then(|children| children.get(id).cloned());

    if let Some(child) = child
        && let Ok(mut locked) = child.lock()
        && let Some(process) = locked.as_mut()
    {
        let _ = process.kill();
    }
}
