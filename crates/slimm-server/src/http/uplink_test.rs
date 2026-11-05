// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin uplink test: this host uploads a fixed body to a speed endpoint and the
//! Mbit/s is kept, so voice settings can size share quality to what the host can send.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::Context;

use axum::Router;
use axum::extract::State;
use axum::routing::get;
use serde::Serialize;
use tokio_util::bytes::Bytes;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;
use crate::store::{UplinkTest, now_ms};

/// Where the body goes unless `SLIMM_UPLINK_TEST_URL` names another endpoint.
const DEFAULT_TARGET: &str = "https://speed.cloudflare.com/__up";
pub const UPLOAD_BYTES: u64 = 40 * 1024 * 1024;
const CHUNK_BYTES: usize = 64 * 1024;
const MAX_DURATION: Duration = Duration::from_secs(20);
const MIN_GAP_MS: i64 = 60_000;

static RUNNING: AtomicBool = AtomicBool::new(false);

pub fn routes() -> Router<AppState> {
    Router::new().route("/space/uplink-test", get(list).post(run))
}

#[derive(Serialize)]
struct UplinkTestDto {
    id: i64,
    measured_at: i64,
    mbit_per_s: f64,
    bytes: i64,
    duration_ms: i64,
}

#[derive(Serialize)]
struct UplinkTestsDto {
    results: Vec<UplinkTestDto>,
}

impl From<UplinkTest> for UplinkTestDto {
    fn from(t: UplinkTest) -> Self {
        Self {
            id: t.id,
            measured_at: t.measured_at,
            mbit_per_s: t.mbit_per_s,
            bytes: t.bytes,
            duration_ms: t.duration_ms,
        }
    }
}

async fn list(
    State(state): State<AppState>,
    parts: axum::http::request::Parts,
    Authed(ctx): Authed,
) -> Result<Json<UplinkTestsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let results = state.store.uplink_tests().await?;
    Ok(Json(UplinkTestsDto {
        results: results.into_iter().map(Into::into).collect(),
    }))
}

struct RunGuard;

impl RunGuard {
    fn take() -> Option<Self> {
        (!RUNNING.swap(true, Ordering::AcqRel)).then_some(Self)
    }
}

impl Drop for RunGuard {
    fn drop(&mut self) {
        RUNNING.store(false, Ordering::Release);
    }
}

async fn run(
    State(state): State<AppState>,
    parts: axum::http::request::Parts,
    Authed(ctx): Authed,
) -> Result<Json<UplinkTestDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    if state.store.any_voice_session_open().await? {
        return Err(ApiError::Conflict("a call is live"));
    }
    let latest = state.store.uplink_tests().await?.into_iter().next();
    if latest.is_some_and(|t| now_ms() - t.measured_at < MIN_GAP_MS) {
        return Err(ApiError::TooManyRequests);
    }
    let _guard = RunGuard::take().ok_or(ApiError::Conflict("a test is already running"))?;
    let target = std::env::var("SLIMM_UPLINK_TEST_URL").unwrap_or_else(|_| DEFAULT_TARGET.into());
    let measured = measure(&target, UPLOAD_BYTES, MAX_DURATION).await;
    let (mbit, bytes, millis) = measured.map_err(|error| {
        tracing::warn!(%error, "uplink test failed");
        ApiError::Unavailable
    })?;
    let stored = state
        .store
        .record_uplink_test(mbit, bytes as i64, millis)
        .await?;
    Ok(Json(stored.into()))
}

/// Uploads `total` bytes to `url` and returns (Mbit/s, bytes counted, milliseconds counted).
///
/// A finished upload counts every byte over the whole time. The sender takes bytes
/// before the network has carried them, so past `limit` its count overstates what was
/// delivered by whatever sits in socket and hyper buffers. That surplus is about the
/// same at the midpoint and at the limit, so a cut-off upload is rated over the second
/// half only, where it cancels out and the rate is a steady-state one; an
/// upload slower than a chunk per half-window rates as 0.
pub async fn measure(url: &str, total: u64, limit: Duration) -> anyhow::Result<(f64, u64, i64)> {
    let sent = Arc::new(AtomicU64::new(0));
    let body = reqwest::Body::wrap_stream(zero_chunks(total, sent.clone()));
    let client = reqwest::Client::builder().build()?;
    let started = Instant::now();
    let request = client.post(url).body(body).send();
    tokio::pin!(request);
    let midpoint = tokio::time::sleep(limit / 2);
    tokio::pin!(midpoint);
    let deadline = tokio::time::sleep(limit);
    tokio::pin!(deadline);
    let mut mark: Option<(u64, Instant)> = None;
    let (bytes, window) = loop {
        tokio::select! {
            response = &mut request => {
                response?.error_for_status()?;
                break (total, started.elapsed());
            }
            () = &mut midpoint, if mark.is_none() => {
                mark = Some((sent.load(Ordering::Acquire), Instant::now()));
            }
            () = &mut deadline => {
                let (at_mark, marked) = mark.context("the limit is too short to rate")?;
                let now = sent.load(Ordering::Acquire);
                anyhow::ensure!(now > 0, "no bytes were sent");
                break (now.saturating_sub(at_mark), marked.elapsed());
            }
        }
    };
    let secs = window.as_secs_f64().max(0.001);
    Ok((
        bytes as f64 * 8.0 / secs / 1_000_000.0,
        bytes,
        window.as_millis() as i64,
    ))
}

fn zero_chunks(
    total: u64,
    sent: Arc<AtomicU64>,
) -> impl futures_util::Stream<Item = Result<Bytes, std::io::Error>> {
    let chunk = Bytes::from(vec![0u8; CHUNK_BYTES]);
    futures_util::stream::unfold(0u64, move |done| {
        let chunk = chunk.clone();
        let sent = sent.clone();
        async move {
            if done >= total {
                return None;
            }
            let take = (total - done).min(CHUNK_BYTES as u64) as usize;
            sent.fetch_add(take as u64, Ordering::AcqRel);
            Some((Ok(chunk.slice(..take)), done + take as u64))
        }
    })
}
