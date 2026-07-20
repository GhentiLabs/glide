//! Shared HTTP plumbing for the remote STT/LLM providers.

use std::time::Duration;

use anyhow::{Context, Result};
use reqwest::{Client, RequestBuilder, Response, StatusCode};

/// Cleanup requests are small; transcription uploads whole recordings.
pub(crate) const LLM_TIMEOUT: Duration = Duration::from_secs(30);
pub(crate) const STT_TIMEOUT: Duration = Duration::from_secs(60);

const RETRY_DELAY: Duration = Duration::from_millis(500);

pub(crate) fn client(timeout: Duration) -> Result<Client> {
    Client::builder()
        .timeout(timeout)
        .build()
        .context("failed to build HTTP client")
}

/// Sends the request produced by `request`, retrying once after a short delay
/// on transient failures: 408/429/5xx responses and any send error (reqwest
/// cannot reliably separate permanent send failures from network flakes, and
/// a wasted retry costs one delay where a missed one costs the dictation).
/// `request` is a factory because request bodies (multipart uploads) cannot be
/// cloned across attempts.
pub(crate) async fn send_with_retry(
    request: impl Fn() -> Result<RequestBuilder>,
    description: &str,
) -> Result<Response> {
    let first = attempt(request()?, description).await;
    if let Ok(response) = &first
        && !transient_status(response.status())
    {
        return first;
    }

    tokio::time::sleep(RETRY_DELAY).await;
    attempt(request()?, description).await
}

async fn attempt(request: RequestBuilder, description: &str) -> Result<Response> {
    request
        .send()
        .await
        .with_context(|| format!("failed to call {description}"))
}

fn transient_status(status: StatusCode) -> bool {
    status == StatusCode::REQUEST_TIMEOUT
        || status == StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error()
}

#[cfg(test)]
mod tests;
