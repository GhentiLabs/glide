use super::{
    downloads::transient_install_state,
    paths::{directory_size, parakeet_model_dir, validate_parakeet_model_dir},
    types::{PARAKEET_MODELS, ParakeetInstallState, ParakeetModelStatus},
};

pub fn parakeet_models_status() -> Vec<ParakeetModelStatus> {
    PARAKEET_MODELS
        .iter()
        .map(|definition| ParakeetModelStatus {
            definition: *definition,
            state: parakeet_install_state(definition.id),
        })
        .collect()
}

pub fn parakeet_install_state(id: &str) -> ParakeetInstallState {
    if let Some(state) = transient_install_state(id) {
        return state;
    }

    let Ok(dir) = parakeet_model_dir(id) else {
        return ParakeetInstallState::NotInstalled;
    };

    if validate_parakeet_model_dir(&dir).is_ok() {
        ParakeetInstallState::Installed {
            size_bytes: directory_size(&dir).unwrap_or(0),
        }
    } else {
        ParakeetInstallState::NotInstalled
    }
}
