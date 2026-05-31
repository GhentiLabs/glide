use std::sync::{Mutex, OnceLock};

use strum::VariantArray as _;

use crate::{
    config::Provider,
    engines::model_assets::{self, ParakeetInstallState},
};

const REMOTE_PROVIDER_COUNT: usize = 5;

pub(super) static PROVIDER_VERIFIED: OnceLock<Mutex<[bool; REMOTE_PROVIDER_COUNT]>> =
    OnceLock::new();

pub(super) fn set_remote_provider_verified(provider: Provider, verified: bool) {
    if let Some(index) = provider.remote_index() {
        remote_provider_state().lock().unwrap()[index] = verified;
    }
}

pub fn provider_verified(provider: Provider) -> bool {
    if let Some(index) = provider.remote_index() {
        return remote_provider_state().lock().unwrap()[index];
    }

    local_provider_verified(provider)
}

pub fn any_provider_verified() -> bool {
    Provider::VARIANTS.iter().copied().any(provider_verified)
}

fn local_provider_verified(provider: Provider) -> bool {
    match provider {
        Provider::AppleLocal => apple_speech_available() || apple_foundation_available(),
        Provider::Parakeet => model_assets::parakeet_models_status()
            .iter()
            .any(|model| matches!(model.state, ParakeetInstallState::Installed { .. })),
        Provider::OpenAi
        | Provider::Groq
        | Provider::Cerebras
        | Provider::Fireworks
        | Provider::ElevenLabs => false,
    }
}

fn apple_speech_available() -> bool {
    model_assets::first_installed_apple_speech_model().is_some()
}

fn apple_foundation_available() -> bool {
    model_assets::first_available_apple_foundation_model().is_some()
}

fn remote_provider_state() -> &'static Mutex<[bool; REMOTE_PROVIDER_COUNT]> {
    PROVIDER_VERIFIED.get_or_init(|| Mutex::new([false; REMOTE_PROVIDER_COUNT]))
}
