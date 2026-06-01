use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::OnceLock,
    thread,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};

use super::{
    archive::safe_extract_tar_bz2_checked,
    paths::{model_assets_dir, parakeet_model_dir, validate_parakeet_model_dir},
    types::{ParakeetInstallState, ParakeetModelDefinition, parakeet_definition},
};
use crate::engines::model_assets::lifecycle::{DownloadRegistry, DownloadRun};

static PARAKEET_DOWNLOADS: OnceLock<DownloadRegistry<ParakeetInstallState>> = OnceLock::new();

struct ParakeetInstallWorkspace {
    install_dir: PathBuf,
    temp_dir: PathBuf,
    archive_path: PathBuf,
}

fn downloads() -> &'static DownloadRegistry<ParakeetInstallState> {
    PARAKEET_DOWNLOADS.get_or_init(DownloadRegistry::new)
}

pub fn start_parakeet_download(id: &str) -> Result<()> {
    let definition =
        *parakeet_definition(id).with_context(|| format!("unknown Parakeet model: {id}"))?;

    let Some(run) = downloads().begin(
        definition.id,
        ParakeetInstallState::Downloading {
            downloaded_bytes: 0,
            total_bytes: None,
        },
    ) else {
        return Ok(());
    };

    thread::spawn(move || {
        finish_parakeet_download(definition, run);
    });

    Ok(())
}

pub fn cancel_parakeet_download(id: &str) -> Result<()> {
    parakeet_definition(id).with_context(|| format!("unknown Parakeet model: {id}"))?;

    downloads().request_cancel(id, parakeet_cancelling_state);

    Ok(())
}

fn parakeet_cancelling_state(state: &ParakeetInstallState) -> ParakeetInstallState {
    match state {
        ParakeetInstallState::Downloading {
            downloaded_bytes,
            total_bytes,
        }
        | ParakeetInstallState::Cancelling {
            downloaded_bytes,
            total_bytes,
        } => ParakeetInstallState::Cancelling {
            downloaded_bytes: *downloaded_bytes,
            total_bytes: *total_bytes,
        },
        _ => state.clone(),
    }
}

pub fn delete_parakeet_model(id: &str) -> Result<()> {
    if downloads().is_active(id) {
        cancel_parakeet_download(id)?;
    } else {
        downloads().clear(id);
    }

    let dir = parakeet_model_dir(id)?;
    if dir.exists() {
        fs::remove_dir_all(&dir)
            .with_context(|| format!("failed to delete model asset at {}", dir.display()))?;
    }
    Ok(())
}

fn finish_parakeet_download(definition: ParakeetModelDefinition, run: DownloadRun) {
    if let Err(error) = download_and_install_parakeet(definition, &run) {
        downloads().finish_error(&run, ParakeetInstallState::Failed(error.to_string()));
    } else {
        downloads().finish_clear(&run);
    }
}

fn download_and_install_parakeet(
    definition: ParakeetModelDefinition,
    run: &DownloadRun,
) -> Result<()> {
    let workspace = ParakeetInstallWorkspace::prepare(definition)?;
    let result = install_parakeet_archive(definition, run, &workspace);

    if result.is_err() {
        workspace.cleanup_temp();
    }

    result
}

fn install_parakeet_archive(
    definition: ParakeetModelDefinition,
    run: &DownloadRun,
    workspace: &ParakeetInstallWorkspace,
) -> Result<()> {
    check_download_cancelled(run)?;
    download_archive(definition, &workspace.archive_path, run)?;
    check_download_cancelled(run)?;
    safe_extract_tar_bz2_checked(&workspace.archive_path, &workspace.temp_dir, || {
        check_download_cancelled(run)
    })?;
    fs::remove_file(&workspace.archive_path).ok();
    check_download_cancelled(run)?;
    validate_parakeet_model_dir(&workspace.temp_dir)?;

    workspace.replace_installed_model()
}

impl ParakeetInstallWorkspace {
    fn prepare(definition: ParakeetModelDefinition) -> Result<Self> {
        let root = model_assets_dir()?;
        fs::create_dir_all(&root).context("failed to create model asset directory")?;

        let install_dir = root.join(definition.id);
        let temp_dir = root.join(format!(
            ".{}-download-{}",
            definition.id,
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()
        ));
        let archive_path = temp_dir.join(definition.archive_name);

        if temp_dir.exists() {
            fs::remove_dir_all(&temp_dir).ok();
        }
        fs::create_dir_all(&temp_dir).context("failed to create temporary model directory")?;

        Ok(Self {
            install_dir,
            temp_dir,
            archive_path,
        })
    }

    fn replace_installed_model(&self) -> Result<()> {
        if self.install_dir.exists() {
            fs::remove_dir_all(&self.install_dir).with_context(|| {
                format!(
                    "failed to replace existing model at {}",
                    self.install_dir.display()
                )
            })?;
        }

        fs::rename(&self.temp_dir, &self.install_dir).with_context(|| {
            format!(
                "failed to move model from {} to {}",
                self.temp_dir.display(),
                self.install_dir.display()
            )
        })
    }

    fn cleanup_temp(&self) {
        fs::remove_dir_all(&self.temp_dir).ok();
    }
}

fn download_archive(
    definition: ParakeetModelDefinition,
    archive_path: &Path,
    run: &DownloadRun,
) -> Result<()> {
    let mut response = reqwest::blocking::get(definition.url)
        .with_context(|| format!("failed to start model download from {}", definition.url))?
        .error_for_status()
        .context("model download returned an error status")?;
    let total = response.content_length();
    let mut file = File::create(archive_path).with_context(|| {
        format!(
            "failed to create model archive at {}",
            archive_path.display()
        )
    })?;

    let mut downloaded = 0u64;
    let mut buffer = [0u8; 1024 * 256];
    loop {
        check_download_cancelled(run)?;
        let read = response
            .read(&mut buffer)
            .context("failed while reading model download")?;
        if read == 0 {
            break;
        }
        check_download_cancelled(run)?;
        file.write_all(&buffer[..read])
            .context("failed while writing model archive")?;
        downloaded += read as u64;
        check_download_cancelled(run)?;
        update_parakeet_download_progress(run, downloaded, total);
    }

    Ok(())
}

fn update_parakeet_download_progress(
    run: &DownloadRun,
    downloaded_bytes: u64,
    total_bytes: Option<u64>,
) {
    downloads().update_if_current(
        run,
        ParakeetInstallState::Downloading {
            downloaded_bytes,
            total_bytes,
        },
        |state| matches!(state, ParakeetInstallState::Downloading { .. }),
    );
}

pub(in crate::engines::model_assets) fn transient_install_state(
    id: &str,
) -> Option<ParakeetInstallState> {
    downloads().state(id)
}

#[cfg(test)]
pub(crate) fn set_parakeet_install_state_for_test(id: &str, state: ParakeetInstallState) {
    let active = matches!(
        state,
        ParakeetInstallState::Downloading { .. } | ParakeetInstallState::Cancelling { .. }
    );
    downloads().set_state_for_test(id, state, active);
}

#[cfg(test)]
pub(in crate::engines::model_assets) fn parakeet_download_state_for_test(
    id: &str,
) -> Option<ParakeetInstallState> {
    downloads().state(id)
}

#[cfg(test)]
pub(in crate::engines::model_assets) fn reset_parakeet_download_for_test(id: &str) {
    downloads().clear(id);
}

fn check_download_cancelled(run: &DownloadRun) -> Result<()> {
    anyhow::ensure!(!run.is_cancelled(), "download cancelled");
    Ok(())
}
