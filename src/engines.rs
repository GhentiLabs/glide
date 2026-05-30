//! Speech & text engines: transcription (STT), cleanup (LLM), on-device
//! local models, the remote model catalog, and the Apple helper subprocess.

pub mod apple_helper;
pub mod llm;
pub mod local_models;
pub mod model_catalog;
pub mod stt;
