use anyhow::{Context, Result};
use reqwest::{Client, multipart};
use serde::Deserialize;

use crate::{
    audio::AudioFormat,
    config::{Provider, ProvidersConfig},
    engines::net,
};

pub struct OpenAiSttProvider {
    provider: Provider,
    client: Client,
    endpoint: String,
    default_model: String,
    api_key: String,
    prompt: Option<String>,
}

impl OpenAiSttProvider {
    pub fn new(
        provider: Provider,
        model: &str,
        providers: &ProvidersConfig,
        vocabulary: &[String],
    ) -> Result<Self> {
        let creds = providers.credentials_for(provider);
        let api_key = creds.resolve_api_key("speech-to-text")?;
        let endpoint = provider.stt_endpoint_for_model(&creds.base_url, model);
        let prompt = vocabulary_prompt(vocabulary);
        let model = if provider == Provider::Fireworks {
            model.rsplit('/').next().unwrap_or(model)
        } else {
            model
        };
        Ok(Self {
            provider,
            client: net::client(net::STT_TIMEOUT)?,
            endpoint,
            default_model: model.to_string(),
            api_key,
            prompt,
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

        let form = multipart::Form::new()
            .text("model", self.default_model.clone())
            .part("file", file_part);

        Ok(match &self.prompt {
            Some(prompt) if !prompt.is_empty() => form.text("prompt", prompt.clone()),
            _ => form,
        })
    }

    fn authenticated_request(&self, form: multipart::Form) -> reqwest::RequestBuilder {
        let request = self.client.post(&self.endpoint).multipart(form);
        if self.provider == Provider::Fireworks {
            request.header(reqwest::header::AUTHORIZATION, &self.api_key)
        } else {
            request.bearer_auth(&self.api_key)
        }
    }
}

#[derive(Debug, Deserialize)]
struct OpenAiTranscriptionResponse {
    text: String,
}

#[async_trait::async_trait]
impl super::SttProvider for OpenAiSttProvider {
    async fn transcribe(&self, audio: &[u8], format: AudioFormat) -> Result<String> {
        let response = net::send_with_retry(
            || Ok(self.authenticated_request(self.request_form(audio, format)?)),
            "transcription API",
        )
        .await?
        .error_for_status()
        .context("transcription API returned an error status")?;

        let parsed: OpenAiTranscriptionResponse = response
            .json()
            .await
            .context("failed to parse transcription response")?;

        Ok(parsed.text.trim().to_string())
    }

    fn name(&self) -> &'static str {
        "STT Provider"
    }
}

fn vocabulary_prompt(vocabulary: &[String]) -> Option<String> {
    let terms: Vec<&str> = vocabulary
        .iter()
        .map(String::as_str)
        .map(str::trim)
        .filter(|term| !term.is_empty())
        .collect();

    if terms.is_empty() {
        None
    } else {
        Some(terms.join(", "))
    }
}

#[cfg(test)]
mod tests {
    use super::vocabulary_prompt;

    #[test]
    fn vocabulary_prompt_is_none_for_empty_vocabulary() {
        assert_eq!(vocabulary_prompt(&[]), None);
    }

    #[test]
    fn vocabulary_prompt_ignores_blank_terms() {
        let vocabulary = vec![
            " Glide ".to_string(),
            "".to_string(),
            "  ".to_string(),
            "GPUI".to_string(),
        ];

        assert_eq!(
            vocabulary_prompt(&vocabulary).as_deref(),
            Some("Glide, GPUI")
        );
    }

    #[test]
    fn vocabulary_prompt_preserves_commas_inside_terms() {
        let vocabulary = vec!["ACME, Inc.".to_string(), "Glide".to_string()];

        assert_eq!(
            vocabulary_prompt(&vocabulary).as_deref(),
            Some("ACME, Inc., Glide")
        );
    }
}
