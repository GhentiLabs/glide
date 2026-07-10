use anyhow::{Context, Result};

use crate::{
    app::state::{RuntimeStatus, SharedState},
    audio::RecordedAudio,
    config::{GlideConfig, ModelSelection, ReplacementRule, Style},
    engines::llm,
    engines::stt,
    platform::paste,
    text::find_ignore_case,
};

pub async fn process_recording(
    shared: SharedState,
    audio: RecordedAudio,
    target_app: Option<String>,
) -> Result<()> {
    let config = shared.config();
    shared.set_status(RuntimeStatus::Processing);

    let matched_style = matched_style(&config, target_app.as_deref());
    let stt_text = run_stt_phase(
        &audio,
        &config,
        effective_stt_selection(&config, matched_style),
    )
    .await?;
    let cleaned_text = run_llm_phase(
        &stt_text,
        &config,
        effective_llm_selection(&config, matched_style),
        matched_style,
    )
    .await?;
    let cleaned_text = strip_model_reasoning(&cleaned_text);

    paste_cleaned_text(&cleaned_text, &config, &shared)?;
    Ok(())
}

fn matched_style<'a>(config: &'a GlideConfig, target_app: Option<&str>) -> Option<&'a Style> {
    target_app.and_then(|target| {
        config.dictation.styles.iter().find(|style| {
            style
                .apps
                .iter()
                .any(|app| app.eq_ignore_ascii_case(target))
        })
    })
}

fn effective_stt_selection<'a>(
    config: &'a GlideConfig,
    matched_style: Option<&'a Style>,
) -> &'a ModelSelection {
    matched_style
        .and_then(|style| style.stt.as_ref())
        .unwrap_or(&config.dictation.stt)
}

fn effective_llm_selection<'a>(
    config: &'a GlideConfig,
    matched_style: Option<&'a Style>,
) -> Option<&'a ModelSelection> {
    matched_style
        .and_then(|style| style.llm.as_ref())
        .or(config.dictation.llm.as_ref())
}

async fn run_stt_phase(
    audio: &RecordedAudio,
    config: &GlideConfig,
    selection: &ModelSelection,
) -> Result<String> {
    eprintln!(
        "[glide] STT: transcribing {} samples via {:?} / {}...",
        audio.sample_count, selection.provider, selection.model
    );

    let stt_provider = stt::build_provider(
        selection.provider,
        &selection.model,
        &config.providers,
        &config.dictionary.vocabulary,
    )
    .context("failed to build STT provider")?;
    let stt_name = stt_provider.name();
    eprintln!("[glide] STT: provider ready");

    let raw_text = stt_provider
        .transcribe(&audio.bytes, audio.format)
        .await
        .with_context(|| format!("{stt_name} transcription failed"))?;

    anyhow::ensure!(
        !raw_text.trim().is_empty(),
        "transcription returned no text"
    );

    let text = apply_replacements(&raw_text, &config.dictionary.replacements);
    eprintln!("[glide] STT: got transcript ({} chars)", text.len());

    Ok(text)
}

async fn run_llm_phase(
    raw_text: &str,
    config: &GlideConfig,
    selection: Option<&ModelSelection>,
    matched_style: Option<&Style>,
) -> Result<String> {
    let Some(selection) = selection else {
        eprintln!("[glide] LLM: disabled, using raw transcript");
        return Ok(raw_text.to_string());
    };

    eprintln!(
        "[glide] LLM: cleaning up via {:?} / {}...",
        selection.provider, selection.model
    );

    let llm_provider = llm::build_provider(
        selection.provider,
        &selection.model,
        config.dictation.system_prompt.as_str(),
        matched_style.map(|style| style.prompt.as_str()),
        &config.providers,
    )
    .context("failed to build LLM provider")?;
    let llm_name = llm_provider.name();
    eprintln!("[glide] LLM: provider ready");

    let cleaned = llm_provider
        .clean(raw_text)
        .await
        .with_context(|| format!("{llm_name} cleanup failed"));
    cleaned.inspect(|text| {
        eprintln!("[glide] LLM: cleanup returned {} chars", text.len());
    })
}

fn strip_model_reasoning(text: &str) -> String {
    // Strip <think>...</think> tags some models emit (e.g. DeepSeek reasoning)
    llm::strip_think_tags(text)
}

fn paste_cleaned_text(text: &str, config: &GlideConfig, shared: &SharedState) -> Result<()> {
    eprintln!("[glide] Pasting {} chars", text.len());
    paste::paste_text(text, &config.paste).context("failed to paste transcript")?;
    eprintln!("[glide] Paste: request returned");
    shared.set_status(RuntimeStatus::Idle);
    eprintln!("[glide] Pipeline: completed");
    Ok(())
}

fn apply_replacements(text: &str, replacements: &[ReplacementRule]) -> String {
    let mut result = text.to_string();
    for rule in replacements {
        if rule.find.is_empty() {
            continue;
        }
        if rule.case_sensitive {
            result = result.replace(&rule.find, &rule.replace);
        } else {
            let mut output = String::with_capacity(result.len());
            let mut rest = result.as_str();
            while let Some(range) = find_ignore_case(rest, &rule.find) {
                output.push_str(&rest[..range.start]);
                output.push_str(&rule.replace);
                rest = &rest[range.end..];
            }
            output.push_str(rest);
            result = output;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::apply_replacements;
    use crate::config::ReplacementRule;

    fn rule(find: &str, replace: &str, case_sensitive: bool) -> ReplacementRule {
        ReplacementRule {
            find: find.to_string(),
            replace: replace.to_string(),
            case_sensitive,
        }
    }

    #[test]
    fn case_sensitive_replacement_only_matches_exact_case() {
        let rules = [rule("Foo", "Bar", true)];
        assert_eq!(apply_replacements("Foo foo Foo", &rules), "Bar foo Bar");
    }

    #[test]
    fn case_insensitive_replacement_matches_any_case() {
        let rules = [rule("hello", "hi", false)];
        assert_eq!(
            apply_replacements("Hello world, HELLO again hello", &rules),
            "hi world, hi again hi"
        );
    }

    #[test]
    fn case_insensitive_replacement_survives_lowercase_length_change() {
        // 'İ' (U+0130) is 2 bytes but lowercases to 3 bytes ("i\u{307}").
        let rules = [rule("abc", "xyz", false)];
        assert_eq!(apply_replacements("İabc", &rules), "İxyz");
    }

    #[test]
    fn case_insensitive_replacement_keeps_text_around_multibyte_chars() {
        let rules = [rule("q", "z", false)];
        assert_eq!(apply_replacements("aİbQc", &rules), "aİbzc");
    }

    #[test]
    fn case_insensitive_find_containing_multibyte_char() {
        let rules = [rule("İstanbul", "Istanbul", false)];
        assert_eq!(
            apply_replacements("İstanbul and İSTANBUL", &rules),
            "Istanbul and Istanbul"
        );
    }
}
