use std::{
    fs, io,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};

use super::types::parakeet_definition;

pub(in crate::engines::model_assets) const REQUIRED_PARAKEET_FILES: [&str; 4] = [
    "encoder.int8.onnx",
    "decoder.int8.onnx",
    "joiner.int8.onnx",
    "tokens.txt",
];

pub fn parakeet_model_dir(id: &str) -> Result<PathBuf> {
    let definition =
        parakeet_definition(id).with_context(|| format!("unknown Parakeet model: {id}"))?;
    Ok(model_assets_dir()?.join(definition.id))
}

pub fn validate_parakeet_model_dir(dir: &Path) -> Result<()> {
    anyhow::ensure!(dir.is_dir(), "model directory does not exist");
    for file in REQUIRED_PARAKEET_FILES {
        let path = dir.join(file);
        anyhow::ensure!(path.is_file(), "missing required model file: {file}");
    }
    Ok(())
}

pub(super) fn model_assets_dir() -> Result<PathBuf> {
    if let Some(path) = env_path("GLIDE_MODEL_ASSETS_DIR") {
        return Ok(path);
    }

    if let Some(path) = env_path("GLIDE_LOCAL_MODELS_DIR") {
        return Ok(path);
    }

    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Glide")
        .join("Models"))
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var(name)
        .ok()
        .filter(|path| !path.trim().is_empty())
        .map(PathBuf::from)
}

pub(super) fn directory_size(path: &Path) -> io::Result<u64> {
    let mut total = 0u64;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        if metadata.is_dir() {
            total += directory_size(&entry.path())?;
        } else {
            total += metadata.len();
        }
    }
    Ok(total)
}
