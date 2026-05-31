use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AudioConfig {
    pub device: String,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            device: "default".to_string(),
        }
    }
}
