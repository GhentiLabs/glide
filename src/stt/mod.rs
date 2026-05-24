use anyhow::Result;

use crate::{
    audio::AudioFormat,
    config::{Provider, ProvidersConfig},
};

mod apple;
mod openai;
mod parakeet;

#[async_trait::async_trait]
pub trait SttProvider: Send + Sync {
    async fn transcribe(&self, audio: &[u8], format: AudioFormat) -> Result<String>;
    fn name(&self) -> &'static str;
}

pub fn build_provider(
    provider: Provider,
    model: &str,
    providers: &ProvidersConfig,
    vocabulary_prompt: Option<String>,
) -> Result<Box<dyn SttProvider>> {
    match provider {
        // OpenAI and Groq use the OpenAI-compatible transcription API format.
        Provider::OpenAi | Provider::Groq => Ok(Box::new(openai::OpenAiSttProvider::new(
            provider,
            model,
            providers,
            vocabulary_prompt,
        )?)),
        Provider::Cerebras => {
            anyhow::bail!("Cerebras does not provide a speech-to-text model")
        }
        Provider::AppleLocal => Ok(Box::new(apple::AppleSpeechProvider::new(
            model,
            vocabulary_prompt,
        )?)),
        Provider::Parakeet => Ok(Box::new(parakeet::ParakeetSttProvider::new(model)?)),
    }
}
