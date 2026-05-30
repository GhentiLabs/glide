mod operations;
mod process;
mod transport;
mod types;

pub use operations::{cached_capabilities, invalidate_capabilities_cache, release_speech_model};
pub(crate) use operations::{
    cleanup_profiled, prewarm_foundation, speech_model_request_json, transcribe_profiled,
};
#[cfg(not(test))]
pub use operations::{foundation_models, speech_models};
pub(crate) use process::{helper_failure_message, helper_path};
pub use types::AppleSpeechInstallProgress;

#[cfg(test)]
use crate::profile::ProfileCollector;
#[cfg(test)]
use process::decode_helper_response;
#[cfg(test)]
use transport::{PersistentHelperClient, decode_persistent_response, persistent_request_json};
#[cfg(test)]
use types::{CleanupRequest, HelperResponse, TranscribeRequest};

#[cfg(test)]
mod tests;
