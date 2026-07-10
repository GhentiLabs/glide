use crate::config::STYLE_PROMPT_PLACEHOLDER;
use crate::text::find_ignore_case;
pub(crate) fn build_cleanup_system_prompt(
    prompt_template: &str,
    style_prompt: Option<&str>,
) -> String {
    let style_prompt = style_prompt.unwrap_or_default().trim();
    prompt_template.replace(STYLE_PROMPT_PLACEHOLDER, style_prompt)
}
pub(crate) fn build_cleanup_user_prompt(raw_text: &str) -> String {
    let mut prompt = String::new();
    let transcript = raw_text.trim();

    prompt.push_str("<dictation_cleanup_request>\n");
    prompt.push_str("<raw_transcript>\n");
    prompt.push_str("<<<GLIDE_RAW_TRANSCRIPT\n");
    prompt.push_str(transcript);
    prompt.push_str("\nGLIDE_RAW_TRANSCRIPT\n");
    prompt.push_str("</raw_transcript>\n\n");
    prompt.push_str("</dictation_cleanup_request>");
    prompt
}
/// Remove `<think>...</think>` blocks from LLM output.
pub(crate) fn strip_think_tags(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut remaining = text;
    while let Some(open) = find_ignore_case(remaining, "<think") {
        result.push_str(&remaining[..open.start]);
        if let Some(close) = find_ignore_case(&remaining[open.start..], "</think") {
            let close_start = open.start + close.end;
            let close_end = remaining[close_start..]
                .find('>')
                .map(|i| close_start + i + 1)
                .unwrap_or(remaining.len());
            remaining = &remaining[close_end..];
        } else {
            remaining = "";
        }
    }
    result.push_str(remaining);
    result.trim().to_string()
}
#[cfg(test)]
mod tests {
    use super::{build_cleanup_system_prompt, build_cleanup_user_prompt, strip_think_tags};

    #[test]
    fn cleanup_system_prompt_inserts_style_placeholder() {
        let prompt =
            build_cleanup_system_prompt("Base\n{{STYLE}}\nDone", Some("  Make it concise.  "));
        assert_eq!(prompt, "Base\nMake it concise.\nDone");
    }

    #[test]
    fn cleanup_system_prompt_without_placeholder_is_unchanged() {
        let prompt = build_cleanup_system_prompt("Base prompt", Some("Make it concise."));
        assert_eq!(prompt, "Base prompt");
    }

    #[test]
    fn cleanup_user_prompt_delimits_transcript() {
        let prompt = build_cleanup_user_prompt("Can you explain the bug?");

        assert!(prompt.starts_with("<dictation_cleanup_request>\n<raw_transcript>\n"));
        assert!(prompt.contains("<raw_transcript>\n<<<GLIDE_RAW_TRANSCRIPT\n"));
        assert!(prompt.contains("Can you explain the bug?\nGLIDE_RAW_TRANSCRIPT\n"));
        assert!(prompt.ends_with("</dictation_cleanup_request>"));
    }

    #[test]
    fn strips_reasoning_blocks() {
        let cases = [
            ("<think>reasoning</think>Hello", "Hello"),
            ("Hi <think>reasoning</think>there", "Hi there"),
            ("<THINK>reasoning</ThInK> Hello", "Hello"),
            ("Answer<think>hidden", "Answer"),
        ];

        for (input, expected) in cases {
            assert_eq!(strip_think_tags(input), expected);
        }
    }

    #[test]
    fn strips_reasoning_after_multibyte_lowercase_expansion() {
        // 'İ' (U+0130) is 2 bytes but lowercases to 3 bytes ("i\u{307}").
        assert_eq!(strip_think_tags("İ<think>x</think>Y"), "İY");
    }

    #[test]
    fn strips_unclosed_reasoning_after_multibyte_prefix() {
        assert_eq!(strip_think_tags("İİİİİİİ<think"), "İİİİİİİ");
    }
}
