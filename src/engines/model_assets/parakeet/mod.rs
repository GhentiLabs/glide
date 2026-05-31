mod archive;
mod downloads;
mod paths;
mod status;
mod types;

pub use downloads::{cancel_parakeet_download, delete_parakeet_model, start_parakeet_download};
pub use paths::{parakeet_model_dir, validate_parakeet_model_dir};
pub use status::{parakeet_install_state, parakeet_models_status};
pub use types::{
    PARAKEET_MODELS, ParakeetInstallState, ParakeetModelDefinition, ParakeetModelStatus,
    parakeet_definition,
};

#[cfg(test)]
pub(in crate::engines::model_assets) use archive::{safe_extract_tar_bz2, strip_archive_root};
#[cfg(test)]
pub(crate) use downloads::set_parakeet_install_state_for_test;
#[cfg(test)]
pub(in crate::engines::model_assets) use downloads::{
    parakeet_download_state_for_test, reset_parakeet_download_for_test,
};
#[cfg(test)]
pub(in crate::engines::model_assets) use paths::REQUIRED_PARAKEET_FILES;
