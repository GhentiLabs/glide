use anyhow::{Context, Result};
use reqwest::{Client, multipart};
use serde::Deserialize;

use crate::{
    audio::AudioFormat,
    config::{Provider, ProvidersConfig},
    engines::net,
};

pub struct ElevenLabsSttProvider {
    client: Client,
    endpoint: String,
    model: String,
    api_key: String,
}

impl ElevenLabsSttProvider {
    pub fn new(model: &str, providers: &ProvidersConfig) -> Result<Self> {
        let creds = providers.credentials_for(Provider::ElevenLabs);
        let api_key = creds.resolve_api_key("ElevenLabs speech-to-text")?;
        let endpoint = Provider::ElevenLabs.stt_endpoint(&creds.base_url);
        Ok(Self {
            client: net::client(net::STT_TIMEOUT),
            endpoint,
            model: model.to_string(),
            api_key,
        })
    }

    fn request_form(&self, audio: &[u8], format: AudioFormat) -> Result<multipart::Form> {
        let mime = match format {
            AudioFormat::Wav => "audio/wav",
        };

        let file_part = multipart::Part::bytes(audio.to_vec())
            .file_name("glide.wav")
            .mime_str(mime)
            .context("failed to create audio upload body")?;

        Ok(multipart::Form::new()
            .text("model_id", self.model.clone())
            .text("file_format", "other")
            .part("file", file_part))
    }
}

#[derive(Debug, Deserialize)]
struct ElevenLabsTranscriptionResponse {
    text: String,
}

#[async_trait::async_trait]
impl super::SttProvider for ElevenLabsSttProvider {
    async fn transcribe(&self, audio: &[u8], format: AudioFormat) -> Result<String> {
        let response = net::send_with_retry(
            || {
                Ok(self
                    .client
                    .post(&self.endpoint)
                    .header("xi-api-key", &self.api_key)
                    .multipart(self.request_form(audio, format)?))
            },
            "ElevenLabs speech-to-text API",
        )
        .await?
        .error_for_status()
        .context("ElevenLabs speech-to-text API returned an error status")?;

        let parsed: ElevenLabsTranscriptionResponse = response
            .json()
            .await
            .context("failed to parse ElevenLabs transcription response")?;

        Ok(parsed.text.trim().to_string())
    }

    fn name(&self) -> &'static str {
        "ElevenLabs STT Provider"
    }
}
