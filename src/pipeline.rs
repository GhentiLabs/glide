use std::time::Instant;

use anyhow::{Context, Result};

use crate::{
    app::state::{RuntimeStatus, SharedState},
    app::trace::{TraceSession, attrs},
    audio::RecordedAudio,
    config::{GlideConfig, ModelSelection, ReplacementRule, Style},
    engines::llm,
    engines::stt,
    platform::paste,
    profile::ProfileCollector,
};

struct SttOutput {
    text: String,
    result_at: Instant,
}

pub async fn process_recording(
    shared: SharedState,
    audio: RecordedAudio,
    target_app: Option<String>,
    trace: TraceSession,
    release_started: Option<Instant>,
) -> Result<()> {
    let pipeline_started = Instant::now();
    let result =
        process_recording_inner(shared, audio, target_app, trace.clone(), release_started).await;
    trace.record("pipeline_total", pipeline_started.elapsed());
    result
}

async fn process_recording_inner(
    shared: SharedState,
    audio: RecordedAudio,
    target_app: Option<String>,
    trace: TraceSession,
    release_started: Option<Instant>,
) -> Result<()> {
    let pipeline_started = Instant::now();
    record_pipeline_start(&trace, &audio, target_app.as_deref());

    if let Some(release_started) = release_started {
        trace.record_since("release_to_pipeline_start", release_started);
    }

    let config = trace.measure("pipeline_config_snapshot", || shared.config());
    trace.measure("pipeline_status_processing", || {
        shared.set_status(RuntimeStatus::Processing)
    });

    let matched_style = trace.measure("pipeline_style_resolution", || {
        matched_style(&config, target_app.as_deref())
    });
    let stt_output = run_stt_phase(
        &audio,
        &config,
        effective_stt_selection(&config, matched_style),
        &trace,
        release_started,
    )
    .await?;
    let cleaned_text = run_llm_phase(
        &stt_output.text,
        &config,
        effective_llm_selection(&config, matched_style),
        matched_style,
        &trace,
        release_started,
        stt_output.result_at,
    )
    .await?;
    let cleaned_text = strip_model_reasoning(&cleaned_text, &trace);

    paste_cleaned_text(
        &cleaned_text,
        &config,
        &shared,
        &trace,
        release_started,
        pipeline_started,
    )?;
    Ok(())
}

fn record_pipeline_start(trace: &TraceSession, audio: &RecordedAudio, target_app: Option<&str>) {
    trace.instant_with_attrs(
        "pipeline_start",
        attrs([
            ("sample_count", audio.sample_count.to_string()),
            ("byte_count", audio.bytes.len().to_string()),
            ("target_app", target_app.unwrap_or("unknown").to_string()),
        ]),
    );
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
    trace: &TraceSession,
    release_started: Option<Instant>,
) -> Result<SttOutput> {
    record_model_selection(trace, "pipeline_stt_selected", selection);
    eprintln!(
        "[glide] STT: transcribing {} samples via {:?} / {}...",
        audio.sample_count, selection.provider, selection.model
    );

    let stt_profile = profile_for_trace(trace);
    let stt_build_started = Instant::now();
    let stt_provider = stt::build_profiled_provider(
        selection.provider,
        &selection.model,
        &config.providers,
        &config.dictionary.vocabulary,
        stt_profile.clone(),
    )
    .context("failed to build STT provider");
    trace.record("pipeline_stt_provider_build", stt_build_started.elapsed());
    let stt_provider = stt_provider?;
    let stt_name = stt_provider.name();
    eprintln!(
        "[glide] STT: provider ready in {} ms",
        elapsed_ms(stt_build_started)
    );

    if let Some(release_started) = release_started {
        trace.record_since("release_to_stt_call_start", release_started);
    }
    let stt_started = Instant::now();
    let raw_text = stt_provider
        .transcribe(&audio.bytes, audio.format)
        .await
        .with_context(|| format!("{stt_name} transcription failed"));
    trace.record("pipeline_stt_call", stt_started.elapsed());
    trace.record_profile_spans("provider_stt", &stt_profile.spans());
    let raw_text = raw_text?;
    let stt_result_at = Instant::now();
    trace.instant_with_attrs(
        "pipeline_stt_result",
        attrs([("char_count", raw_text.chars().count().to_string())]),
    );

    anyhow::ensure!(
        !raw_text.trim().is_empty(),
        "transcription returned no text"
    );

    let text = trace.measure("pipeline_replacements", || {
        apply_replacements(&raw_text, &config.dictionary.replacements)
    });
    eprintln!(
        "[glide] STT: got transcript ({} chars) in {} ms",
        text.len(),
        elapsed_ms(stt_started)
    );

    Ok(SttOutput {
        text,
        result_at: stt_result_at,
    })
}

async fn run_llm_phase(
    raw_text: &str,
    config: &GlideConfig,
    selection: Option<&ModelSelection>,
    matched_style: Option<&Style>,
    trace: &TraceSession,
    release_started: Option<Instant>,
    stt_result_at: Instant,
) -> Result<String> {
    let Some(selection) = selection else {
        trace.instant("pipeline_llm_disabled");
        trace.record_since("stt_result_to_paste_candidate", stt_result_at);
        eprintln!("[glide] LLM: disabled, using raw transcript");
        return Ok(raw_text.to_string());
    };

    record_model_selection(trace, "pipeline_llm_selected", selection);
    eprintln!(
        "[glide] LLM: cleaning up via {:?} / {}...",
        selection.provider, selection.model
    );

    let llm_profile = profile_for_trace(trace);
    let llm_build_started = Instant::now();
    let llm_provider = llm::build_profiled_provider(
        selection.provider,
        &selection.model,
        config.dictation.system_prompt.as_str(),
        matched_style.map(|style| style.prompt.as_str()),
        &config.providers,
        llm_profile.clone(),
    )
    .context("failed to build LLM provider");
    trace.record("pipeline_llm_provider_build", llm_build_started.elapsed());
    let llm_provider = llm_provider?;
    let llm_name = llm_provider.name();
    eprintln!(
        "[glide] LLM: provider ready in {} ms",
        elapsed_ms(llm_build_started)
    );

    trace.record_since("stt_result_to_llm_call_start", stt_result_at);
    if let Some(release_started) = release_started {
        trace.record_since("release_to_llm_call_start", release_started);
    }

    let llm_started = Instant::now();
    let cleaned = llm_provider
        .clean(raw_text)
        .await
        .with_context(|| format!("{llm_name} cleanup failed"));
    trace.record("pipeline_llm_call", llm_started.elapsed());
    trace.record_profile_spans("provider_llm", &llm_profile.spans());
    cleaned.inspect(|text| {
        trace.instant_with_attrs(
            "pipeline_llm_result",
            attrs([("char_count", text.chars().count().to_string())]),
        );
        eprintln!(
            "[glide] LLM: cleanup returned {} chars in {} ms",
            text.len(),
            elapsed_ms(llm_started)
        );
    })
}

fn record_model_selection(trace: &TraceSession, event: &str, selection: &ModelSelection) {
    trace.instant_with_attrs(
        event,
        attrs([
            ("provider", format!("{:?}", selection.provider)),
            ("model", selection.model.clone()),
        ]),
    );
}

fn strip_model_reasoning(text: &str, trace: &TraceSession) -> String {
    // Strip <think>...</think> tags some models emit (e.g. DeepSeek reasoning)
    trace.measure("pipeline_strip_think_tags", || llm::strip_think_tags(text))
}

fn paste_cleaned_text(
    text: &str,
    config: &GlideConfig,
    shared: &SharedState,
    trace: &TraceSession,
    release_started: Option<Instant>,
    pipeline_started: Instant,
) -> Result<()> {
    eprintln!("[glide] Pasting {} chars", text.len());
    if let Some(release_started) = release_started {
        trace.record_since("release_to_paste_start", release_started);
    }
    let paste_started = Instant::now();
    paste::paste_text(text, &config.paste).context("failed to paste transcript")?;
    trace.record("pipeline_paste", paste_started.elapsed());
    eprintln!(
        "[glide] Paste: request returned in {} ms",
        elapsed_ms(paste_started)
    );
    trace.measure("pipeline_status_idle", || {
        shared.set_status(RuntimeStatus::Idle)
    });
    eprintln!(
        "[glide] Pipeline: completed in {} ms",
        elapsed_ms(pipeline_started)
    );
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

fn elapsed_ms(started: Instant) -> u128 {
    started.elapsed().as_millis()
}

fn profile_for_trace(trace: &TraceSession) -> ProfileCollector {
    if trace.is_enabled() {
        ProfileCollector::enabled()
    } else {
        ProfileCollector::disabled()
    }
}
