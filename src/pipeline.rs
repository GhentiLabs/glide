use anyhow::{Context, Result};

use crate::{
    app::state::{RuntimeStatus, SharedState},
    audio::RecordedAudio,
    config::{GlideConfig, ModelSelection, ReplacementRule, Style},
    engines::llm,
    engines::stt,
    platform::paste,
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
            let lower_find = rule.find.to_lowercase();
            let mut search_start = 0;
            let lower_result = result.to_lowercase();
            while let Some(pos) = lower_result[search_start..].find(&lower_find) {
                let abs_pos = search_start + pos;
                output.push_str(&result[search_start..abs_pos]);
                output.push_str(&rule.replace);
                search_start = abs_pos + rule.find.len();
            }
            output.push_str(&result[search_start..]);
            result = output;
        }
    }
    result
}
