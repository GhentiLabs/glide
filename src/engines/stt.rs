//! Speech-to-text: the first pipeline stage. Turns recorded audio into a raw
//! transcript. Mirrors the shape of [`crate::engines::llm`] (provider trait +
//! factory) but takes audio and returns text, where LLM takes text and returns
//! cleaned-up text.

use anyhow::Result;

use crate::{
    audio::AudioFormat,
    config::{Provider, ProvidersConfig},
};

mod apple;
mod elevenlabs;
mod openai;
mod parakeet;

#[async_trait::async_trait]
pub trait SttProvider: Send + Sync {
    async fn transcribe(&self, audio: &[u8], format: AudioFormat) -> Result<String>;
    fn name(&self) -> &'static str;
}

pub(crate) fn build_provider(
    provider: Provider,
    model: &str,
    providers: &ProvidersConfig,
    vocabulary: &[String],
) -> Result<Box<dyn SttProvider>> {
    match provider {
        // OpenAI, Groq, and Fireworks use OpenAI-style multipart transcription APIs.
        Provider::OpenAi | Provider::Groq | Provider::Fireworks => Ok(Box::new(
            openai::OpenAiSttProvider::new(provider, model, providers, vocabulary)?,
        )),
        Provider::ElevenLabs => Ok(Box::new(elevenlabs::ElevenLabsSttProvider::new(
            model, providers,
        )?)),
        Provider::Cerebras => {
            anyhow::bail!("Cerebras does not provide a speech-to-text model")
        }
        Provider::AppleLocal => Ok(Box::new(apple::AppleSpeechProvider::new(model)?)),
        Provider::Parakeet => Ok(Box::new(parakeet::ParakeetSttProvider::new(model)?)),
    }
}

pub(crate) fn prewarm_provider(provider: Provider, model: &str) -> Result<()> {
    match provider {
        Provider::Parakeet => parakeet::prewarm_model(model),
        _ => Ok(()),
    }
}
