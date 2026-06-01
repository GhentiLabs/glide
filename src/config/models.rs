use serde::{Deserialize, Serialize};

use super::providers::Provider;

const DEFAULT_PROMPT: &str = include_str!("prompts/default.md");
const PROFESSIONAL_PROMPT: &str = include_str!("prompts/professional.md");
const MESSAGING_PROMPT: &str = include_str!("prompts/messaging.md");
const CODING_PROMPT: &str = include_str!("prompts/coding.md");
pub const STYLE_PROMPT_PLACEHOLDER: &str = "{{STYLE}}";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelSelection {
    pub provider: Provider,
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Style {
    pub name: String,
    #[serde(default)]
    pub apps: Vec<String>,
    pub prompt: String,
    #[serde(default)]
    pub stt: Option<ModelSelection>,
    #[serde(default)]
    pub llm: Option<ModelSelection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct DictationConfig {
    pub stt: ModelSelection,
    pub llm: Option<ModelSelection>,
    pub system_prompt: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub system_prompt_uses_default: bool,
    pub styles: Vec<Style>,
    #[serde(default)]
    pub smart_defaults_applied: bool,
}

impl Default for DictationConfig {
    fn default() -> Self {
        Self {
            stt: ModelSelection {
                provider: Provider::OpenAi,
                model: "whisper-1".to_string(),
            },
            llm: None,
            smart_defaults_applied: false,
            system_prompt: DEFAULT_PROMPT.trim_end().to_string(),
            system_prompt_uses_default: true,
            styles: default_styles(),
        }
    }
}

impl DictationConfig {
    pub fn default_system_prompt() -> &'static str {
        DEFAULT_PROMPT.trim_end()
    }

    pub fn sync_system_prompt_default_flag(&mut self) {
        self.system_prompt_uses_default =
            normalized_prompt(&self.system_prompt) == Self::default_system_prompt();
    }

    pub fn refresh_builtin_prompt_defaults(&mut self) {
        let prompt_matches_default =
            normalized_prompt(&self.system_prompt) == Self::default_system_prompt();

        if self.system_prompt_uses_default || prompt_matches_default {
            if prompt_matches_default {
                self.system_prompt = Self::default_system_prompt().to_string();
                self.system_prompt_uses_default = true;
            } else {
                self.system_prompt_uses_default = false;
            }
        }

        for style in &mut self.styles {
            if let Some(default_prompt) =
                default_style_prompt_if_unedited(&style.name, &style.prompt)
            {
                style.prompt = default_prompt.to_string();
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplacementRule {
    pub find: String,
    pub replace: String,
    #[serde(default)]
    pub case_sensitive: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct DictionaryConfig {
    pub vocabulary: Vec<String>,
    pub replacements: Vec<ReplacementRule>,
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn default_styles() -> Vec<Style> {
    [
        ("Professional", PROFESSIONAL_PROMPT),
        ("Messaging", MESSAGING_PROMPT),
        ("Coding", CODING_PROMPT),
    ]
    .into_iter()
    .map(|(name, prompt)| Style {
        name: name.to_string(),
        apps: vec![],
        prompt: prompt.trim_end().to_string(),
        stt: None,
        llm: None,
    })
    .collect()
}

fn normalized_prompt(prompt: &str) -> &str {
    prompt.trim_end()
}

fn default_style_prompt_if_unedited(name: &str, prompt: &str) -> Option<&'static str> {
    let current = match name {
        "Professional" => PROFESSIONAL_PROMPT.trim_end(),
        "Messaging" => MESSAGING_PROMPT.trim_end(),
        "Coding" => CODING_PROMPT.trim_end(),
        _ => return None,
    };

    (normalized_prompt(prompt) == current).then_some(current)
}

#[cfg(test)]
mod tests {
    use super::{DictationConfig, STYLE_PROMPT_PLACEHOLDER};

    #[test]
    fn default_prompt_contains_cleanup_contract_and_style_placeholder() {
        let config = DictationConfig::default();
        assert!(config.system_prompt_uses_default);
        assert!(config.system_prompt.contains("CORE TASK:"));
        assert!(config.system_prompt.contains(STYLE_PROMPT_PLACEHOLDER));
        assert!(
            config
                .system_prompt
                .contains("Preserve spoken questions as questions")
        );

        for style in &config.styles {
            assert!(!style.prompt.contains("CORE TASK:"), "{} style", style.name);
            assert!(
                !style.prompt.contains("raw transcript"),
                "{} style",
                style.name
            );
            assert!(
                style.prompt.len() < 400,
                "{} style should be short",
                style.name
            );
        }
    }

    #[test]
    fn refresh_builtin_prompt_defaults_preserves_custom_prompt() {
        let mut config = DictationConfig::default();
        config.system_prompt = "custom prompt".to_string();
        config.system_prompt_uses_default = true;

        config.refresh_builtin_prompt_defaults();

        assert_eq!(config.system_prompt, "custom prompt");
        assert!(!config.system_prompt_uses_default);
    }

    #[test]
    fn sync_system_prompt_default_flag_tracks_current_default() {
        let mut config = DictationConfig::default();
        config.system_prompt = "custom prompt".to_string();
        config.sync_system_prompt_default_flag();
        assert!(!config.system_prompt_uses_default);

        config.system_prompt = DictationConfig::default_system_prompt().to_string();
        config.sync_system_prompt_default_flag();
        assert!(config.system_prompt_uses_default);
    }
}
