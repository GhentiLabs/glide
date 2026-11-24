use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};

use crate::config::{Provider, ProvidersConfig};

use super::build_cleanup_user_prompt;

const ERROR_BODY_CHAR_LIMIT: usize = 4096;
pub struct OpenAiLlmProvider {
    client: Client,
    provider: Provider,
    endpoint: String,
    model: String,
    system_prompt: String,
    api_key: String,
}
impl OpenAiLlmProvider {
    pub fn new(
        provider: Provider,
        model: &str,
        system_prompt: &str,
        providers: &ProvidersConfig,
    ) -> Result<Self> {
        let creds = providers.credentials_for(provider);
        let api_key = creds.resolve_api_key("LLM")?;
        let endpoint = provider.llm_endpoint(&creds.base_url);
        Ok(Self {
            client: Client::new(),
            provider,
            endpoint,
            model: model.to_string(),
            system_prompt: system_prompt.to_string(),
            api_key,
        })
    }
}
#[derive(Debug, Serialize)]
struct ChatCompletionRequest {
    model: String,
    messages: Vec<ChatMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_effort: Option<&'static str>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct ChatMessage {
    role: String,
    content: String,
}

#[derive(Debug, Deserialize)]
struct ChatCompletionResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Debug, Deserialize)]
struct ChatChoice {
    message: ChatMessage,
}
#[async_trait::async_trait]
impl super::LlmProvider for OpenAiLlmProvider {
    async fn clean(&self, raw_text: &str) -> Result<String> {
        let user_prompt = build_cleanup_user_prompt(raw_text);
        let request = ChatCompletionRequest {
            model: self.model.clone(),
            temperature: deterministic_temperature(self.provider, &self.model),
            reasoning_effort: reasoning_effort(&self.model),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: self.system_prompt.clone(),
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: user_prompt,
                },
            ],
        };

        let response = self
            .client
            .post(&self.endpoint)
            .bearer_auth(&self.api_key)
            .json(&request)
            .send()
            .await
            .with_context(|| {
                format!(
                    "failed to call {} chat completions API",
                    self.provider.label()
                )
            })?;
        let status = response.status();
        if !status.is_success() {
            let body = response
                .text()
                .await
                .unwrap_or_else(|error| format!("<failed to read error response body: {error}>"));
            anyhow::bail!(
                "{} chat completions API returned HTTP {status}: {}",
                self.provider.label(),
                capped_error_body(&body)
            );
        }

        let parsed: ChatCompletionResponse = response
            .json()
            .await
            .context("failed to parse OpenAI chat response")?;

        let cleaned = parsed
            .choices
            .first()
            .map(|choice| choice.message.content.trim().to_string())
            .context("OpenAI chat response did not include any choices")?;

        Ok(cleaned)
    }

    fn name(&self) -> &'static str {
        self.provider.label()
    }
}
// We use a deterministic temperature (0.0) for models that support it, however
// I'm not sure if this is the best approach; this needs to be benchmarked.
fn deterministic_temperature(provider: Provider, model: &str) -> Option<f32> {
    if provider == Provider::OpenAi && openai_model_rejects_temperature_zero(model) {
        None
    } else {
        Some(0.0)
    }
}

fn openai_model_rejects_temperature_zero(model: &str) -> bool {
    let model = model.trim().to_lowercase();
    model.starts_with("gpt-5") || model.starts_with('o')
}

// gpt-oss models reason before answering; low effort keeps dictation cleanup
// fast (on Groq: ~7 reasoning tokens instead of ~300) with identical output.
fn reasoning_effort(model: &str) -> Option<&'static str> {
    model.to_lowercase().contains("gpt-oss").then_some("low")
}
fn capped_error_body(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return "<empty response body>".to_string();
    }
    if trimmed.chars().count() <= ERROR_BODY_CHAR_LIMIT {
        return trimmed.to_string();
    }

    let prefix = trimmed
        .chars()
        .take(ERROR_BODY_CHAR_LIMIT)
        .collect::<String>();
    format!("{prefix}... [truncated]")
}
#[cfg(test)]
mod tests;
