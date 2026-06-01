use std::{
    fs::{self, File},
    io::Read,
    path::{Component, Path, PathBuf},
};

use anyhow::{Context, Result};
use bzip2::read::BzDecoder;

pub(super) fn safe_extract_tar_bz2_checked(
    archive_path: &Path,
    destination: &Path,
    mut check_cancelled: impl FnMut() -> Result<()>,
) -> Result<()> {
    let archive_file = File::open(archive_path)
        .with_context(|| format!("failed to open model archive {}", archive_path.display()))?;
    let decoder = BzDecoder::new(archive_file);
    let mut archive = tar::Archive::new(decoder);

    for entry in archive.entries().context("failed to read model archive")? {
        check_cancelled()?;
        let mut entry = entry.context("failed to read model archive entry")?;
        unpack_archive_entry(&mut entry, destination)?;
        check_cancelled()?;
    }

    Ok(())
}

#[cfg(test)]
pub(in crate::engines::model_assets) fn safe_extract_tar_bz2(
    archive_path: &Path,
    destination: &Path,
) -> Result<()> {
    safe_extract_tar_bz2_checked(archive_path, destination, || Ok(()))
}

fn unpack_archive_entry<R: Read>(entry: &mut tar::Entry<'_, R>, destination: &Path) -> Result<()> {
    let safe_path = {
        let entry_path = entry.path().context("failed to read model archive path")?;
        strip_archive_root(&entry_path)?
    };

    if safe_path.as_os_str().is_empty() {
        return Ok(());
    }

    let out_path = destination.join(safe_path);
    if entry.header().entry_type().is_dir() {
        fs::create_dir_all(&out_path)
            .with_context(|| format!("failed to create {}", out_path.display()))?;
    } else {
        if let Some(parent) = out_path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        entry
            .unpack(&out_path)
            .with_context(|| format!("failed to unpack {}", out_path.display()))?;
    }

    Ok(())
}

pub(in crate::engines::model_assets) fn strip_archive_root(path: &Path) -> Result<PathBuf> {
    let mut components = path.components();
    let _root = components.next();
    let mut stripped = PathBuf::new();

    for component in components {
        match component {
            Component::Normal(part) => stripped.push(part),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                anyhow::bail!("archive contains an unsafe path: {}", path.display());
            }
        }
    }

    Ok(stripped)
}
