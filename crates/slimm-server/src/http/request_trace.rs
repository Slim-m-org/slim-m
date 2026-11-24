// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-request log lines that leave out unauthenticated noise.
//!
//! A `/healthz` probe or a request no route matched costs an attacker nothing,
//! so a line for each would let anyone rotate real evidence out of the
//! retained log files. Both are skipped here; every other request keeps its
//! start and finish line.

use std::time::Duration;

use axum::extract::Request;
use axum::http::Response;
use axum::response::IntoResponse;
use tower_http::trace::{DefaultOnRequest, DefaultOnResponse, OnRequest, OnResponse};
use tracing::Span;

pub const LIVENESS_PATH: &str = "/healthz";

/// Marks a response the router's fallback produced, so it is logged as noise.
#[derive(Clone, Copy)]
pub struct Unmatched;

/// The router fallback: a bare 404 flagged [`Unmatched`].
pub async fn unmatched() -> impl IntoResponse {
    let mut response = axum::http::StatusCode::NOT_FOUND.into_response();
    response.extensions_mut().insert(Unmatched);
    response
}

/// The request span, or none for a request whose lines are not worth keeping.
pub fn make_span(request: &Request) -> Span {
    if request.uri().path() == LIVENESS_PATH {
        return Span::none();
    }
    let route = request
        .extensions()
        .get::<axum::extract::MatchedPath>()
        .map(axum::extract::MatchedPath::as_str)
        .unwrap_or("unmatched");
    tracing::info_span!("http_request", method = %request.method(), route)
}

#[derive(Clone, Default)]
pub struct QuietOnRequest(DefaultOnRequest);

impl<B> OnRequest<B> for QuietOnRequest {
    fn on_request(&mut self, request: &axum::http::Request<B>, span: &Span) {
        if !span.is_none() {
            self.0.on_request(request, span);
        }
    }
}

#[derive(Clone, Default)]
pub struct QuietOnResponse(DefaultOnResponse);

impl<B> OnResponse<B> for QuietOnResponse {
    fn on_response(self, response: &Response<B>, latency: Duration, span: &Span) {
        if !span.is_none() && response.extensions().get::<Unmatched>().is_none() {
            self.0.on_response(response, latency, span);
        }
    }
}
