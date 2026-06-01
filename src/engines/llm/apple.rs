use anyhow::Result;

use crate::engines::apple_bridge;

use super::build_cleanup_user_prompt;

pub struct AppleFoundationLlmProvider {
    model_id: String,
    system_prompt: String,
}

impl AppleFoundationLlmProvider {
    pub fn new(model_id: &str, system_prompt: &str) -> Self {
        Self {
            model_id: model_id.to_string(),
            system_prompt: system_prompt.to_string(),
        }
    }
}

#[async_trait::async_trait]
impl super::LlmProvider for AppleFoundationLlmProvider {
    async fn clean(&self, raw_text: &str) -> Result<String> {
        let user_prompt = build_cleanup_user_prompt(raw_text);
        let model_id = self.model_id.clone();
        let system_prompt = self.system_prompt.clone();
        tokio::task::spawn_blocking(move || {
            apple_bridge::cleanup(&model_id, &system_prompt, &user_prompt)
        })
        .await?
    }

    fn name(&self) -> &'static str {
        "Apple Foundation Models"
    }
}
