// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /metrics` in Prometheus text format: memory, request counts and
//! latency, pool and connection gauges, the memory guard's view, and whether
//! the SFU answers. Gated on `MANAGE_SERVER` because traffic volume is a
//! signal about a private community; see docs/internals.md.

use axum::Router;
use axum::extract::{Extension, State};
use axum::http::request::Parts;
use axum::http::{HeaderValue, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, enforce, require_manage_server};
use super::route_timing::{self, RouteTimings};
use crate::process_metrics::current_rss_bytes;
use crate::ratelimit::Class;

/// The metrics route, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new().route("/metrics", get(metrics))
}

/// `route_timings` arrives as an [`Extension`], not part of [`AppState`]:
/// that struct is built literally at well over a hundred call sites across
/// the integration tests (see `http.rs`'s own note on `min_client_version`),
/// and an `Extension` layered once in `router` reaches this handler - and
/// `route_timing::record` - with none of those call sites touched.
async fn metrics(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Extension(route_timings): Extension<RouteTimings>,
) -> Result<Response, ApiError> {
    // Write, not AuthedRead: write_voice probes the SFU live on every call.
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;

    let mut body = String::new();
    write_memory(&mut body);
    write_requests(&mut body, &state);
    write_route_latency(&mut body, &route_timings);
    write_pool(&mut body, &state);
    write_connections(&mut body, &state);
    write_memory_admission(&mut body, &state);
    write_voice(&mut body, &state).await;

    let mut response = body.into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; version=0.0.4; charset=utf-8"),
    );
    Ok(response)
}

/// Per-route request latency, one Prometheus histogram
/// (`_bucket`/`_sum`/`_count`) per method and route template. See
/// `route_timing`'s own doc for why the route is a matched template rather
/// than a raw path.
fn write_route_latency(out: &mut String, timings: &RouteTimings) {
    out.push_str(
        "# HELP slimm_http_request_duration_seconds HTTP request latency by method and matched route template.\n",
    );
    out.push_str("# TYPE slimm_http_request_duration_seconds histogram\n");
    for route in timings.snapshot() {
        let method = route.method.as_str();
        let path = &route.route;
        for (bound, count) in route_timing::BUCKET_BOUNDS_SECONDS
            .iter()
            .zip(route.bucket_counts.iter())
        {
            out.push_str(&format!(
                "slimm_http_request_duration_seconds_bucket{{method=\"{method}\",route=\"{path}\",le=\"{bound}\"}} {count}\n"
            ));
        }
        out.push_str(&format!(
            "slimm_http_request_duration_seconds_bucket{{method=\"{method}\",route=\"{path}\",le=\"+Inf\"}} {}\n",
            route.count
        ));
        out.push_str(&format!(
            "slimm_http_request_duration_seconds_sum{{method=\"{method}\",route=\"{path}\"}} {}\n",
            route.sum_seconds
        ));
        out.push_str(&format!(
            "slimm_http_request_duration_seconds_count{{method=\"{method}\",route=\"{path}\"}} {}\n",
            route.count
        ));
    }
}

/// SQLite pool occupancy - the shared resource every read and write on this
/// server contends for, so how much of it is checked out is the most direct
/// saturation signal `/metrics` can give.
fn write_pool(out: &mut String, state: &AppState) {
    let stats = state.store.pool_stats();
    out.push_str(
        "# HELP slimm_db_pool_connections_max The pool's configured connection ceiling.\n",
    );
    out.push_str("# TYPE slimm_db_pool_connections_max gauge\n");
    out.push_str(&format!("slimm_db_pool_connections_max {}\n", stats.max));

    out.push_str("# HELP slimm_db_pool_connections Connections currently open in the pool, idle or in use.\n");
    out.push_str("# TYPE slimm_db_pool_connections gauge\n");
    out.push_str(&format!("slimm_db_pool_connections {}\n", stats.size));

    out.push_str(
        "# HELP slimm_db_pool_connections_in_use Connections currently checked out for a query.\n",
    );
    out.push_str("# TYPE slimm_db_pool_connections_in_use gauge\n");
    out.push_str(&format!(
        "slimm_db_pool_connections_in_use {}\n",
        stats.in_use
    ));
}

fn write_memory(out: &mut String) {
    out.push_str(
        "# HELP slimm_process_resident_memory_bytes Resident memory of this server process.\n",
    );
    out.push_str("# TYPE slimm_process_resident_memory_bytes gauge\n");
    match current_rss_bytes() {
        Some(bytes) => out.push_str(&format!("slimm_process_resident_memory_bytes {bytes}\n")),
        // `NaN` is a legal Prometheus float: this platform genuinely cannot answer, not a zero.
        None => out.push_str("slimm_process_resident_memory_bytes NaN\n"),
    }
}

/// Requests admitted and refused per rate-limit class - the closest thing
/// this server has to a per-route request counter, and reused rather than
/// duplicated: every authenticated write, read, upload, and canvas action
/// already passes through one of these classes to be charged at all, so
/// counting there covers message and request volume alike with no second
/// counter to keep in step.
fn write_requests(out: &mut String, state: &AppState) {
    let counts = state.limiter.counts();

    out.push_str(
        "# HELP slimm_requests_total Requests admitted per rate-limit class since process start.\n",
    );
    out.push_str("# TYPE slimm_requests_total counter\n");
    for (class, count) in &counts {
        out.push_str(&format!(
            "slimm_requests_total{{class=\"{}\"}} {}\n",
            class.label(),
            count.admitted
        ));
    }
    out.push_str(
        "# HELP slimm_requests_refused_total Requests refused for exceeding their class's rate-limit budget.\n",
    );
    out.push_str("# TYPE slimm_requests_refused_total counter\n");
    for (class, count) in &counts {
        out.push_str(&format!(
            "slimm_requests_refused_total{{class=\"{}\"}} {}\n",
            class.label(),
            count.refused
        ));
    }
}

fn write_connections(out: &mut String, state: &AppState) {
    out.push_str("# HELP slimm_websocket_connections Currently open WebSocket connections.\n");
    out.push_str("# TYPE slimm_websocket_connections gauge\n");
    out.push_str(&format!(
        "slimm_websocket_connections {}\n",
        state.hub.connection_count()
    ));
}

/// The connection-admission memory guard: the ceiling and usage it
/// discovered (both absent together when no cgroup limit could be found,
/// the same "absent, not a misleading zero" shape `write_voice` below uses
/// for `slimm_livekit_reachable`), and a running count of refusals.
fn write_memory_admission(out: &mut String, state: &AppState) {
    let snapshot = state.hub.memory_admission_snapshot();

    if let Some(limit) = snapshot.limit_bytes {
        out.push_str(
            "# HELP slimm_memory_limit_bytes Cgroup memory ceiling the connection-admission guard discovered.\n",
        );
        out.push_str("# TYPE slimm_memory_limit_bytes gauge\n");
        out.push_str(&format!("slimm_memory_limit_bytes {limit}\n"));
    }

    if let Some(usage) = snapshot.usage_bytes {
        out.push_str(
            "# HELP slimm_memory_usage_bytes Memory the connection-admission guard counts as in use.\n",
        );
        out.push_str("# TYPE slimm_memory_usage_bytes gauge\n");
        out.push_str(&format!("slimm_memory_usage_bytes {usage}\n"));
    }

    out.push_str(
        "# HELP slimm_memory_admission_refused_total New connections refused for low memory headroom since process start.\n",
    );
    out.push_str("# TYPE slimm_memory_admission_refused_total counter\n");
    out.push_str(&format!(
        "slimm_memory_admission_refused_total {}\n",
        snapshot.refused_total
    ));
}

/// The SFU gauges. `slimm_livekit_reachable` is emitted only when an SFU is
/// configured at all - a text-only deployment has nothing to be unreachable,
/// and a bare `0` there would read as an outage rather than a choice.
async fn write_voice(out: &mut String, state: &AppState) {
    out.push_str(
        "# HELP slimm_livekit_configured Whether this deployment has an SFU configured.\n",
    );
    out.push_str("# TYPE slimm_livekit_configured gauge\n");
    out.push_str(&format!(
        "slimm_livekit_configured {}\n",
        i32::from(state.voice.is_enabled())
    ));

    if let Some(reachable) = state.voice.probe_reachable().await {
        out.push_str(
            "# HELP slimm_livekit_reachable Whether the configured SFU answered the last reachability probe.\n",
        );
        out.push_str("# TYPE slimm_livekit_reachable gauge\n");
        out.push_str(&format!(
            "slimm_livekit_reachable {}\n",
            i32::from(reachable)
        ));
    }
}
