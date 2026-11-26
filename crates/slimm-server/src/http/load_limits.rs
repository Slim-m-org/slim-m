// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How much work the HTTP surface admits: request and body timeouts, the
//! in-flight caps, and the liveness probe that sits outside them.

use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::{Request, State};
use axum::http::header::RETRY_AFTER;
use axum::http::{HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use tokio::sync::Semaphore;
use tower_http::timeout::TimeoutLayer;

use super::{AppState, error};

/// How long one HTTP request may take before it is abandoned.
///
/// The socket surface has had a bound like this from the start, with a comment
/// saying why: a peer that stops reading could otherwise wedge its task
/// indefinitely. The HTTP surface had none, against a process whose measured
/// idle RSS is 7 MB and whose committed budget is under 30 MB. Generous enough
/// for the heaviest real request (a bundled `/sync`) and far short of forever.
/// An attachment upload gets [`Media::upload_timeout`] instead: a gigabyte over
/// a home uplink needs minutes.
pub(super) const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// The routes that take a base64 package or image pack as JSON get this instead.
///
/// The client waits as long for the body to go out over a slow uplink, so a
/// shorter server window would answer 504 before the client gave up.
pub const SLOW_BODY_TIMEOUT: Duration = Duration::from_secs(180);

/// How long a request body may trickle in before it is abandoned.
///
/// Separate from [`REQUEST_TIMEOUT`] because this is the cheaper attack: a
/// request that declares a body and then sends a byte a minute holds a task and
/// its partial buffer for as long as it likes. Caddy's own read-body timeout
/// defaults to unlimited, so the shipped proxy does not cover this either.
pub(super) const BODY_READ_TIMEOUT: Duration = Duration::from_secs(15);

/// How many HTTP requests may be in flight at once.
///
/// The equivalent of `hub::MAX_CONNECTIONS` for the other surface, and set to
/// the same order of magnitude for the same reason: past some number, admitting
/// more work makes every request slower rather than serving anybody. Requests
/// over it wait up to [`INFLIGHT_WAIT`] for a slot and are then shed, so a
/// burst is absorbed and a flood is bounded. Attachment uploads count against
/// [`MAX_INFLIGHT_UPLOADS`] instead, and `/healthz` against neither.
pub(super) const MAX_INFLIGHT_REQUESTS: usize = 1024;

/// How long a request waits for an in-flight slot before it is shed with a 503.
///
/// Short because the slots are shared by every route: a client that holds them
/// by trickling a body would otherwise queue unrelated requests for as long as
/// it keeps them, up to [`REQUEST_TIMEOUT`].
pub(super) const INFLIGHT_WAIT: Duration = Duration::from_secs(2);

/// How many attachment uploads and speed-test transfers may be in flight at once.
///
/// Its own pool because these run for minutes: counting them in
/// [`MAX_INFLIGHT_REQUESTS`] would let a few slow uploads queue every ordinary request.
pub(super) const MAX_INFLIGHT_UPLOADS: usize = 1024;

/// Caps `router` at `max` requests in flight across all its routes together.
///
/// A request that finds no slot free within `wait` is answered 503 with
/// `Retry-After` instead of queueing on. Public so a test can wrap routes of
/// its own. `tower`'s `ConcurrencyLimitLayer` builds a semaphore per service it
/// wraps and `Router::layer` wraps every route and method separately, so it
/// would cap each of them at `max` instead.
pub fn cap_inflight<S: Clone + Send + Sync + 'static>(
    router: Router<S>,
    max: usize,
    wait: Duration,
) -> Router<S> {
    let slots = Arc::new(Semaphore::new(max));
    router.layer(axum::middleware::from_fn(
        move |request: Request, next: Next| {
            let slots = slots.clone();
            async move {
                let Ok(Ok(slot)) = tokio::time::timeout(wait, slots.acquire_owned()).await else {
                    return shed_response();
                };
                let response = next.run(request).await;
                drop(slot);
                response
            }
        },
    ))
}

fn shed_response() -> Response {
    let mut response = error::ApiError::Unavailable.into_response();
    response
        .headers_mut()
        .insert(RETRY_AFTER, HeaderValue::from_static("1"));
    response
}

/// `/healthz` with the request timeout but outside the in-flight cap.
///
/// Queued behind a saturated cap the probe would time out exactly when the
/// process is busiest, which reads as unhealthy the same way a 429 would.
pub(super) fn liveness_route() -> Router<AppState> {
    Router::new()
        .route("/healthz", get(healthz))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::GATEWAY_TIMEOUT,
            REQUEST_TIMEOUT,
        ))
}

/// Liveness probe: 200 while the process is serving and the database answers.
///
/// Deliberately the one route that charges no rate limit. A probe is what an
/// orchestrator calls to decide whether this process is alive, and a 429 there
/// reads as unhealthy and gets the container restarted - so throttling it turns
/// a flood into an outage rather than preventing one. It costs one indexed
/// `SELECT 1`, and the request timeout on [`liveness_route`] bounds it.
async fn healthz(State(state): State<AppState>) -> Result<&'static str, StatusError> {
    state.store.ping().await.map_err(|_| StatusError)?;
    Ok("ok")
}

/// Minimal error so a failed liveness check returns 503 rather than panicking.
struct StatusError;

impl axum::response::IntoResponse for StatusError {
    fn into_response(self) -> axum::response::Response {
        (axum::http::StatusCode::SERVICE_UNAVAILABLE, "unavailable").into_response()
    }
}
