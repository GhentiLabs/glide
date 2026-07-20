//! The model knowledge Glide ships with: per-provider defaults and the
//! pre-fetch picker fallback. The live-fetched catalog supersedes the
//! fallback and validates the defaults, so entries here only need updating
//! when the preferred default for a provider changes.

use crate::config::Provider;

use super::catalog::{model_info, model_info_with_display};
use super::types::ModelInfo;

pub(super) const STT_REMOTE_DEFAULTS: &[(Provider, &str)] = &[
    (Provider::Groq, "whisper-large-v3-turbo"),
    (Provider::OpenAi, "whisper-1"),
    (Provider::Fireworks, "whisper-v3-turbo"),
    (Provider::ElevenLabs, "scribe_v2"),
];

pub const LLM_REMOTE_DEFAULTS: &[(Provider, &str)] = &[
    (Provider::Groq, "llama-3.3-70b-versatile"),
    (Provider::OpenAi, "gpt-5.4-nano"),
    (Provider::Fireworks, "accounts/fireworks/models/gpt-oss-20b"),
    (Provider::Cerebras, "gpt-oss-120b"),
];

pub(super) fn known_remote_stt_models() -> Vec<ModelInfo> {
    vec![
        model_info(Provider::OpenAi, "whisper-1", false),
        model_info(Provider::Groq, "whisper-large-v3", false),
        model_info(Provider::Groq, "whisper-large-v3-turbo", false),
        model_info(Provider::Fireworks, "whisper-v3-turbo", false),
        model_info(Provider::Fireworks, "whisper-v3", false),
        model_info_with_display(Provider::ElevenLabs, "scribe_v2", "Scribe v2", false),
        model_info_with_display(Provider::ElevenLabs, "scribe_v1", "Scribe v1", false),
    ]
}

pub(super) fn known_remote_llm_models() -> Vec<ModelInfo> {
    vec![
        model_info(Provider::OpenAi, "gpt-5.4-nano", false),
        model_info(Provider::OpenAi, "gpt-4o-mini", false),
        model_info(Provider::OpenAi, "gpt-4o", false),
        model_info(Provider::OpenAi, "gpt-4-turbo", false),
        model_info(Provider::Groq, "openai/gpt-oss-20b", false),
        model_info(Provider::Groq, "llama-3.3-70b-versatile", false),
        model_info(Provider::Groq, "llama-3.1-8b-instant", false),
        model_info(
            Provider::Fireworks,
            "accounts/fireworks/models/gpt-oss-20b",
            false,
        ),
        model_info(
            Provider::Fireworks,
            "accounts/fireworks/models/gpt-oss-120b",
            false,
        ),
        model_info(Provider::Cerebras, "gpt-oss-120b", false),
        model_info(Provider::Cerebras, "llama-4-scout-17b-16e-instruct", false),
    ]
}
