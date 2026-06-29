use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use super::{GlideConfig, Provider};

const KEYRING_SERVICE: &str = "glide";
const KEYRING_ACCOUNT: &str = "provider-api-keys";

/// Mirror of the keychain's provider-keys payload, so `save` can skip keychain
/// access (and its auth prompt) when the keys are unchanged.
static KEYRING_MIRROR: Mutex<KeyringMirror> = Mutex::new(KeyringMirror::Unknown);

enum KeyringMirror {
    Unknown,
    Synced(Option<String>),
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct ProviderKeyringPayload {
    version: u8,
    api_keys: BTreeMap<String, String>,
}

pub fn asset_path(relative: &str) -> PathBuf {
    let exe = std::env::current_exe().unwrap_or_default();
    let bundle_resources = exe
        .parent()
        .and_then(|p| p.parent())
        .map(|p| p.join("Resources").join(relative));
    if let Some(ref p) = bundle_resources
        && p.exists()
    {
        return p.clone();
    }
    std::env::current_dir().unwrap_or_default().join(relative)
}

pub(super) fn backup_config_file(path: &Path) -> Result<Option<PathBuf>> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("config.toml");
    let backup_path = path.with_file_name(format!("{file_name}.corrupt-{timestamp}.bak"));

    match std::fs::rename(path, &backup_path) {
        Ok(()) => Ok(Some(backup_path)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error)
            .with_context(|| format!("failed to back up corrupt config at {}", path.display())),
    }
}

pub(super) fn provider_keys_from_config(config: &GlideConfig) -> BTreeMap<String, String> {
    let mut keys = BTreeMap::new();
    for (provider, credentials) in config.providers.remote_credentials() {
        let Some(key_id) = provider.key_id() else {
            continue;
        };
        insert_provider_key(&mut keys, key_id, &credentials.api_key);
    }
    keys
}

fn insert_provider_key(keys: &mut BTreeMap<String, String>, provider: &str, key: &str) {
    if !key.trim().is_empty() {
        keys.insert(provider.to_string(), key.to_string());
    }
}

pub(super) fn load_provider_keys_from_keyring() -> BTreeMap<String, String> {
    let keys = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
        .and_then(|e| e.get_password())
        .ok()
        .map(|raw| decode_provider_keys(&raw))
        .unwrap_or_default();

    *KEYRING_MIRROR.lock().expect("keyring mirror poisoned") =
        KeyringMirror::Synced(encode_provider_keys(&keys));

    keys
}

#[cfg(not(test))]
pub(super) fn save_provider_keys_to_keyring(keys: &BTreeMap<String, String>) {
    let payload = encode_provider_keys(keys);

    let mut mirror = KEYRING_MIRROR.lock().expect("keyring mirror poisoned");
    if let KeyringMirror::Synced(current) = &*mirror
        && *current == payload
    {
        return;
    }

    let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT) else {
        return;
    };
    match payload {
        Some(payload) => {
            if entry.set_password(&payload).is_ok() {
                *mirror = KeyringMirror::Synced(Some(payload));
            }
        }
        None => match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => *mirror = KeyringMirror::Synced(None),
            Err(_) => *mirror = KeyringMirror::Unknown,
        },
    }
}

pub(super) fn encode_provider_keys(keys: &BTreeMap<String, String>) -> Option<String> {
    let api_keys = keys
        .iter()
        .filter(|(_, key)| !key.trim().is_empty())
        .map(|(provider, key)| (provider.clone(), key.clone()))
        .collect::<BTreeMap<_, _>>();

    if api_keys.is_empty() {
        return None;
    }

    serde_json::to_string(&ProviderKeyringPayload {
        version: 1,
        api_keys,
    })
    .ok()
}

pub(super) fn decode_provider_keys(raw: &str) -> BTreeMap<String, String> {
    serde_json::from_str::<ProviderKeyringPayload>(raw)
        .map(|payload| payload.api_keys)
        .or_else(|_| serde_json::from_str::<BTreeMap<String, String>>(raw))
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(provider, key)| {
            let provider = Provider::from_key_id(&provider)?;
            let key_id = provider.key_id()?;
            (!key.trim().is_empty()).then(|| (key_id.to_string(), key))
        })
        .collect()
}
