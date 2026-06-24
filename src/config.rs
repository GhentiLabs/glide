mod app;
mod audio;
mod hotkey;
pub mod models;
mod overlay;
mod paste;
pub mod providers;
mod storage;

#[allow(unused_imports)]
pub use app::MenuBarIcon;
pub use app::{AppConfig, ColorAccent, ThemePreference};
pub use audio::AudioConfig;
pub use hotkey::{HotkeyConfig, HotkeyTrigger, modifier_flag_for_keycode};
pub use models::{
    DictationConfig, DictionaryConfig, ModelSelection, ReplacementRule, STYLE_PROMPT_PLACEHOLDER,
    Style,
};
pub use overlay::{GlowVariant, OverlayConfig, OverlayPosition, OverlayStyle};
pub use paste::PasteConfig;
pub use providers::{Provider, ProviderCredentials, ProvidersConfig};
pub use storage::asset_path;

use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

const CONFIG_APP_NAME: &str = "glide";
const CONFIG_NAME: &str = "config";

#[cfg(test)]
use storage::{
    backup_config_file, decode_provider_keys, encode_provider_keys, provider_keys_from_config,
};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct GlideConfig {
    pub app: AppConfig,
    pub hotkey: HotkeyConfig,
    pub audio: AudioConfig,
    pub providers: ProvidersConfig,
    pub dictation: DictationConfig,
    pub dictionary: DictionaryConfig,
    pub overlay: OverlayConfig,
    pub paste: PasteConfig,
}

impl GlideConfig {
    pub fn load_or_create() -> Result<Self> {
        let mut config: Self =
            confy::load(CONFIG_APP_NAME, CONFIG_NAME).context("failed to load Glide config")?;
        config.dictation.refresh_builtin_prompt_defaults();

        let api_keys = storage::load_provider_keys_from_keyring();
        for provider in Provider::REMOTE {
            let Some(key_id) = provider.key_id() else {
                continue;
            };
            config.providers.credentials_for_mut(provider).api_key =
                api_keys.get(key_id).cloned().unwrap_or_default();
        }

        config.validate()?;
        Ok(config)
    }

    pub fn save(&self) -> Result<()> {
        self.validate()?;
        #[cfg(not(test))]
        {
            confy::store(CONFIG_APP_NAME, CONFIG_NAME, self)
                .map_err(|e| anyhow::anyhow!("failed to save config: {e}"))?;
            storage::save_provider_keys_to_keyring(&storage::provider_keys_from_config(self));
        }
        Ok(())
    }

    pub fn config_file_path() -> Result<PathBuf> {
        confy::get_configuration_file_path(CONFIG_APP_NAME, CONFIG_NAME)
            .context("failed to locate Glide config file")
    }

    pub fn reset_to_default() -> Result<Option<PathBuf>> {
        let path = Self::config_file_path()?;
        let backup_path = storage::backup_config_file(&path)?;

        #[cfg(not(test))]
        {
            let config = Self::default();
            confy::store(CONFIG_APP_NAME, CONFIG_NAME, &config)
                .map_err(|e| anyhow::anyhow!("failed to reset config: {e}"))?;
        }

        Ok(backup_path)
    }

    pub fn validate(&self) -> Result<()> {
        anyhow::ensure!(self.overlay.width > 0, "overlay.width must be positive");
        anyhow::ensure!(self.overlay.height > 0, "overlay.height must be positive");
        anyhow::ensure!(
            (0.0..=1.0).contains(&self.overlay.opacity),
            "overlay.opacity must be between 0 and 1"
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests;
