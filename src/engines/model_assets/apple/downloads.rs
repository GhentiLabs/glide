use std::{
    collections::HashMap,
    io::{BufRead, BufReader, Read, Write},
    process::{Child, ChildStderr, ChildStdout, Command, Stdio},
    sync::{Arc, Mutex, OnceLock},
    thread,
};

use anyhow::{Context, Result};

use crate::engines::apple_bridge::{self, AppleSpeechInstallProgress};
use crate::engines::model_assets::lifecycle::{DownloadFinish, DownloadRegistry, DownloadRun};

use super::{
    speech::{
        apple_speech_locale_id, apple_speech_model_definition, invalidate_apple_speech_model_cache,
    },
    types::AppleSpeechInstallState,
};

type AppleSpeechDownloadChild = Arc<Mutex<Option<Child>>>;

#[derive(Clone)]
struct AppleSpeechDownloadChildEntry {
    run_id: u64,
    child: AppleSpeechDownloadChild,
}

#[derive(Default)]
struct AppleSpeechInstallOutcome {
    saw_finished: bool,
    helper_error: Option<String>,
}

static APPLE_SPEECH_DOWNLOADS: OnceLock<DownloadRegistry<AppleSpeechInstallState>> =
    OnceLock::new();
static APPLE_SPEECH_DOWNLOAD_CHILDREN: OnceLock<
    Mutex<HashMap<String, AppleSpeechDownloadChildEntry>>,
> = OnceLock::new();

fn downloads() -> &'static DownloadRegistry<AppleSpeechInstallState> {
    APPLE_SPEECH_DOWNLOADS.get_or_init(DownloadRegistry::new)
}

fn download_children() -> &'static Mutex<HashMap<String, AppleSpeechDownloadChildEntry>> {
    APPLE_SPEECH_DOWNLOAD_CHILDREN.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn start_apple_speech_model_download(id: &str) -> Result<()> {
    let definition = apple_speech_model_definition(id)
        .with_context(|| format!("unknown Apple Speech model: {id}"))?;

    let Some(run) = downloads().begin(
        &definition.id,
        AppleSpeechInstallState::Downloading { progress: None },
    ) else {
        return Ok(());
    };

    let model_id = definition.id.clone();
    thread::spawn(move || {
        finish_apple_speech_model_download(run, model_id);
    });

    Ok(())
}

pub fn cancel_apple_speech_model_download(id: &str) -> Result<()> {
    anyhow::ensure!(
        apple_speech_locale_id(id).is_some(),
        "unknown Apple Speech model: {id}"
    );

    if let Some(run) = downloads().request_cancel(id, |_| AppleSpeechInstallState::Cancelling) {
        kill_apple_speech_download_child(&run);
    }

    Ok(())
}

pub fn release_apple_speech_model(id: &str) -> Result<()> {
    if downloads().is_active(id) {
        cancel_apple_speech_model_download(id)?;
        return Ok(());
    }

    apple_bridge::release_speech_model(id)?;
    downloads().clear(id);
    invalidate_apple_speech_model_cache();
    Ok(())
}

pub fn apple_speech_has_active_downloads() -> bool {
    downloads().any_active()
}

fn finish_apple_speech_model_download(run: DownloadRun, model_id: String) {
    if let Err(error) = download_and_install_apple_speech_model(&run) {
        if matches!(
            downloads().finish_error(&run, AppleSpeechInstallState::Failed(error.to_string())),
            DownloadFinish::Cancelled
        ) {
            let _ = apple_bridge::release_speech_model(&model_id);
        }
    } else {
        downloads().finish_clear(&run);
    }

    clear_apple_speech_download_child(&run);
    invalidate_apple_speech_model_cache();
}

fn download_and_install_apple_speech_model(run: &DownloadRun) -> Result<()> {
    let (child_handle, stdout, mut stderr) = start_apple_speech_installer(run)?;
    let outcome = read_apple_speech_install_progress(run, stdout)?;

    let mut child = child_handle
        .lock()
        .ok()
        .and_then(|mut locked| locked.take())
        .context("Apple Speech helper process handle was unavailable")?;
    let status = child.wait().context("failed to wait for Apple helper")?;
    let mut stderr_output = String::new();
    let _ = stderr.read_to_string(&mut stderr_output);
    if run.is_cancelled() {
        anyhow::bail!("download cancelled");
    }
    if !status.success() {
        anyhow::bail!(
            "{}",
            apple_bridge::helper_failure_message("install-speech-model", &status, &stderr_output)
        );
    }
    if let Some(error) = outcome.helper_error {
        anyhow::bail!("{error}");
    }
    anyhow::ensure!(
        status.success() && outcome.saw_finished,
        "Apple Speech install did not complete"
    );

    Ok(())
}

fn start_apple_speech_installer(
    run: &DownloadRun,
) -> Result<(AppleSpeechDownloadChild, ChildStdout, ChildStderr)> {
    let helper = apple_bridge::helper_path()?;
    let input = apple_bridge::speech_model_request_json(run.id())?;
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
    let stderr = child
        .stderr
        .take()
        .context("failed to open Apple helper stderr")?;
    let child_handle = Arc::new(Mutex::new(Some(child)));
    set_apple_speech_download_child(run, child_handle.clone());

    Ok((child_handle, stdout, stderr))
}

fn read_apple_speech_install_progress(
    run: &DownloadRun,
    stdout: ChildStdout,
) -> Result<AppleSpeechInstallOutcome> {
    let mut outcome = AppleSpeechInstallOutcome::default();

    for line in BufReader::new(stdout).lines() {
        let line = line.context("failed to read Apple Speech install progress")?;
        if line.trim().is_empty() {
            continue;
        }

        let progress = serde_json::from_str::<AppleSpeechInstallProgress>(line.trim())
            .with_context(|| format!("failed to parse Apple Speech install progress: {line}"))?;

        if !progress.model_id.is_empty() && progress.model_id != run.id() {
            continue;
        }

        if !progress.ok {
            outcome.helper_error = Some(
                progress
                    .error
                    .unwrap_or_else(|| "Apple Speech install failed".to_string()),
            );
            break;
        }

        match progress.event.as_str() {
            "finished" => {
                outcome.saw_finished = true;
                update_apple_speech_download_progress(run, Some(1.0));
            }
            "progress" => {
                update_apple_speech_download_progress(run, progress_fraction(&progress));
            }
            _ => {}
        }
    }

    Ok(outcome)
}

fn update_apple_speech_download_progress(run: &DownloadRun, progress: Option<f64>) {
    downloads().update_if_current(
        run,
        AppleSpeechInstallState::Downloading { progress },
        |state| matches!(state, AppleSpeechInstallState::Downloading { .. }),
    );
}

fn progress_fraction(progress: &AppleSpeechInstallProgress) -> Option<f64> {
    progress
        .fraction_completed
        .map(|value| value.clamp(0.0, 1.0))
        .or_else(|| {
            let total = progress.total_unit_count?;
            let completed = progress.completed_unit_count?;
            (total > 0).then_some((completed as f64 / total as f64).clamp(0.0, 1.0))
        })
}

pub(in crate::engines::model_assets) fn apple_speech_transient_install_state(
    id: &str,
) -> Option<AppleSpeechInstallState> {
    downloads().state(id)
}

#[cfg(test)]
pub(in crate::engines::model_assets) fn apple_speech_download_state_for_test(
    id: &str,
) -> Option<AppleSpeechInstallState> {
    downloads().state(id)
}

#[cfg(test)]
pub(in crate::engines::model_assets) fn set_apple_speech_download_state_for_test(
    id: &str,
    state: AppleSpeechInstallState,
) {
    if matches!(
        state,
        AppleSpeechInstallState::Downloading { .. } | AppleSpeechInstallState::Cancelling
    ) {
        downloads().set_active_for_test(id, state);
    } else {
        downloads().set_inactive_for_test(id, state);
    }
}

#[cfg(test)]
pub(in crate::engines::model_assets) fn reset_apple_speech_download_for_test(id: &str) {
    downloads().clear(id);
    clear_apple_speech_download_child_for_test(id);
}

fn set_apple_speech_download_child(run: &DownloadRun, child: AppleSpeechDownloadChild) {
    if let Ok(mut children) = download_children().lock() {
        children.insert(
            run.id().to_string(),
            AppleSpeechDownloadChildEntry {
                run_id: run.run_id(),
                child,
            },
        );
    }
}

fn clear_apple_speech_download_child(run: &DownloadRun) {
    if let Ok(mut children) = download_children().lock() {
        if children
            .get(run.id())
            .is_some_and(|entry| entry.run_id == run.run_id())
        {
            children.remove(run.id());
        }
    }
}

#[cfg(test)]
fn clear_apple_speech_download_child_for_test(id: &str) {
    if let Ok(mut children) = download_children().lock() {
        children.remove(id);
    }
}

fn kill_apple_speech_download_child(run: &DownloadRun) {
    if let Some(child) = current_apple_speech_download_child(run)
        && let Ok(mut locked) = child.lock()
        && let Some(process) = locked.as_mut()
    {
        let _ = process.kill();
    }
}

fn current_apple_speech_download_child(run: &DownloadRun) -> Option<AppleSpeechDownloadChild> {
    download_children().lock().ok().and_then(|children| {
        children
            .get(run.id())
            .filter(|entry| entry.run_id == run.run_id())
            .map(|entry| entry.child.clone())
    })
}
