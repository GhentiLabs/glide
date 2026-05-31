pub const APPLE_SPEECH_MODEL_PREFIX: &str = "speechanalyzer-";
pub const APPLE_FOUNDATION_MODEL_ID: &str = "apple-foundation-default";

#[cfg(not(test))]
pub(super) const APPLE_FOUNDATION_MODEL_DEFINITIONS: [(&str, &str, &str); 1] = [(
    APPLE_FOUNDATION_MODEL_ID,
    "Apple Foundation Model",
    "SystemLanguageModel.default",
)];

#[derive(Debug, Clone, PartialEq)]
pub enum AppleSpeechInstallState {
    NotInstalled,
    Downloading { progress: Option<f64> },
    Cancelling,
    Installed,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleSpeechModelDefinition {
    pub id: String,
    pub display_name: String,
    pub locale_id: String,
    pub asset_status: String,
    pub(super) reserved: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AppleSpeechModelStatus {
    pub definition: AppleSpeechModelDefinition,
    pub state: AppleSpeechInstallState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleFoundationModelStatus {
    pub id: String,
    pub display_name: String,
    pub model_name: String,
    pub available: bool,
    pub reason: String,
}
