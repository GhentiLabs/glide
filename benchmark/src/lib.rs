mod check_models;
mod cli;
mod compare;
mod prompt_eval;
mod report;
mod runner;
mod types;

pub use cli::{parse_cli_args, run_cli};
pub use compare::{compare_report_files, compare_reports};
pub use glide::benchmark_support::Provider;
pub use report::{phase_summary, redacted_base_url_host, summarize_runs};
pub use types::{
    AudioMetadata, BenchCommand, BenchmarkPhase, BenchmarkReport, BenchmarkRun, CompareFailure,
    CompareOptions, CompareResult, CompareRow, EnvironmentMetadata, FlowBenchOptions,
    LlmBenchOptions, PhaseSummary, PromptEvalCandidate, PromptEvalCandidateReport,
    PromptEvalOptions, PromptEvalReport, PromptEvalResult, PromptEvalSummary, PromptEvalTagSummary,
    ProviderModelMetadata, ScenarioMetadata, SttBenchOptions, TextSummary,
};

const REPORT_SCHEMA_VERSION: u8 = 1;

#[cfg(test)]
use check_models::{missing_models, shipped_models};
#[cfg(test)]
use cli::parse_prompt_eval_candidate;
#[cfg(test)]
use glide::benchmark_support::AudioFormat;
#[cfg(test)]
use prompt_eval::{
    normalize_prompt_eval_text, prompt_eval_result, read_prompt_eval_suite,
    score_prompt_eval_output, summarize_prompt_eval_results,
};
#[cfg(test)]
use report::environment_metadata;
#[cfg(test)]
use runner::load_wav_audio;
#[cfg(test)]
use types::PromptEvalCase;

#[cfg(test)]
mod tests;
