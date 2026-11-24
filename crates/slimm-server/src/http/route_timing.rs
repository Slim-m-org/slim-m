// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-route HTTP request latency, recorded continuously in-process and
//! exposed on `/metrics` as a Prometheus histogram.
//!
//! Labelled by the *matched route template* (`axum::extract::MatchedPath`,
//! e.g. `/channels/{channel_id}/messages`) and method, never by the raw
//! request path: a caller controls parts of that path on many routes (an
//! id, a search term), and labelling by it would let anyone mint unbounded
//! series just by varying the URL. `write_requests` in `http/metrics.rs`
//! already avoids that same trap by keying on rate-limit class instead of
//! path; keying on the route template is safe the same way, since the
//! template is one of a small, fixed set this binary mounts at compile
//! time, not something a request supplies.
//!
//! Wired in with [`super::router`]'s `route_layer`, not a whole-router
//! `layer`: `MatchedPath` is only present in a request's extensions once
//! axum has matched it to a route, and `route_layer`'s middleware runs
//! inside that match; a plain `layer` would see the request before
//! dispatch, with no route to label it by.
//!
//! Each call to [`super::router`] builds its own [`RouteTimings`], the same
//! way it builds its own [`crate::ratelimit::RateLimiter`] - so two test
//! routers in the same process never share counts, and a long-running
//! server carries exactly one.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use axum::extract::{Extension, MatchedPath, Request};
use axum::http::Method;
use axum::middleware::Next;
use axum::response::Response;

/// Upper bounds of every finite histogram bucket, in seconds. The same
/// shape the Prometheus client libraries default to, which covers a fast
/// in-process SQLite read (low milliseconds) up through a request nudging
/// this server's own 30-second timeout.
pub const BUCKET_BOUNDS_SECONDS: [f64; 11] = [
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
];

/// Cumulative bucket counts (Prometheus's own convention: the `le="x"`
/// bucket holds every observation at or below `x`) plus the running sum and
/// total, which is exactly what a `_bucket`/`_sum`/`_count` histogram
/// exposition needs.
#[derive(Default)]
struct Histogram {
    bucket_counts: [u64; BUCKET_BOUNDS_SECONDS.len()],
    sum_seconds: f64,
    count: u64,
}

impl Histogram {
    fn observe(&mut self, seconds: f64) {
        for (bound, bucket) in BUCKET_BOUNDS_SECONDS
            .iter()
            .zip(self.bucket_counts.iter_mut())
        {
            if seconds <= *bound {
                *bucket += 1;
            }
        }
        self.sum_seconds += seconds;
        self.count += 1;
    }
}

/// One route's exported shape: [`BUCKET_BOUNDS_SECONDS`]-aligned cumulative
/// counts, the running sum, and the total - everything `/metrics` needs to
/// print a `_bucket`/`_sum`/`_count` histogram for this method and route.
pub struct RouteSnapshot {
    pub method: &'static str,
    pub route: String,
    pub bucket_counts: [u64; BUCKET_BOUNDS_SECONDS.len()],
    pub sum_seconds: f64,
    pub count: u64,
}

/// A cloneable handle to a process's per-route latency histograms.
#[derive(Clone, Default)]
pub struct RouteTimings {
    inner: Arc<Mutex<HashMap<(&'static str, String), Histogram>>>,
}

impl RouteTimings {
    pub fn new() -> Self {
        Self::default()
    }

    fn observe(&self, method: &'static str, route: String, seconds: f64) {
        let mut inner = match self.inner.lock() {
            Ok(guard) => guard,
            // A poisoned lock loses one sample rather than wedging every request.
            Err(poisoned) => poisoned.into_inner(),
        };
        inner.entry((method, route)).or_default().observe(seconds);
    }

    /// A snapshot for `/metrics`, sorted by route then method so the
    /// exposition text is stable from one scrape to the next.
    pub fn snapshot(&self) -> Vec<RouteSnapshot> {
        let inner = match self.inner.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        let mut snapshots: Vec<RouteSnapshot> = inner
            .iter()
            .map(|((method, route), histogram)| RouteSnapshot {
                method,
                route: route.clone(),
                bucket_counts: histogram.bucket_counts,
                sum_seconds: histogram.sum_seconds,
                count: histogram.count,
            })
            .collect();
        snapshots.sort_by(|a, b| (a.route.as_str(), a.method).cmp(&(b.route.as_str(), b.method)));
        snapshots
    }
}

/// The fixed label a method is recorded under; any extension method is `OTHER`
/// so a caller cannot mint series by inventing method names.
pub fn method_label(method: &Method) -> &'static str {
    match *method {
        Method::GET => "GET",
        Method::HEAD => "HEAD",
        Method::POST => "POST",
        Method::PUT => "PUT",
        Method::PATCH => "PATCH",
        Method::DELETE => "DELETE",
        Method::OPTIONS => "OPTIONS",
        Method::CONNECT => "CONNECT",
        Method::TRACE => "TRACE",
        _ => "OTHER",
    }
}

/// The `route_layer` middleware that records every matched request's
/// latency. Reads its [`RouteTimings`] handle from an [`Extension`] rather
/// than [`axum::extract::State`], so `router` can hand the same instance to
/// both this middleware and the `/metrics` handler without adding a field
/// to [`super::AppState`] - see `metrics::routes`'s own doc for why that
/// matters here.
///
/// Falls back to a fixed `"unmatched"` label rather than the raw path on the
/// one request shape that could reach here without a `MatchedPath` - a
/// `route_layer`-wrapped handler running before its own route has been
/// recorded into the extensions - so the cardinality bound above holds even
/// then.
pub async fn record(
    Extension(timings): Extension<RouteTimings>,
    req: Request,
    next: Next,
) -> Response {
    let method = method_label(req.method());
    let route = req
        .extensions()
        .get::<MatchedPath>()
        .map(|matched| matched.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".to_owned());
    let start = Instant::now();
    let response = next.run(req).await;
    timings.observe(method, route, start.elapsed().as_secs_f64());
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observations_are_bucketed_cumulatively() {
        let timings = RouteTimings::new();
        timings.observe("GET", "/channels".to_owned(), 0.003);
        timings.observe("GET", "/channels".to_owned(), 0.2);

        let snapshot = timings
            .snapshot()
            .into_iter()
            .find(|s| s.route == "/channels" && s.method == "GET")
            .expect("the observed route is present");
        assert_eq!(snapshot.count, 2);
        assert!((snapshot.sum_seconds - 0.203).abs() < 1e-9);
        // 0.003s falls in every bucket; 0.2s only in 0.25s and above.
        assert_eq!(
            snapshot.bucket_counts[0], 1,
            "the 0.005s bucket sees only the fast one"
        );
        let quarter_second_index = BUCKET_BOUNDS_SECONDS
            .iter()
            .position(|&b| b == 0.25)
            .unwrap();
        assert_eq!(snapshot.bucket_counts[quarter_second_index], 2);
    }

    #[test]
    fn routes_and_methods_are_independent() {
        let timings = RouteTimings::new();
        timings.observe("GET", "/a".to_owned(), 0.01);
        timings.observe("POST", "/a".to_owned(), 0.01);
        timings.observe("GET", "/b".to_owned(), 0.01);

        let snapshot = timings.snapshot();
        assert_eq!(snapshot.len(), 3);
    }

    #[test]
    fn a_thousand_invented_methods_share_one_label() {
        let timings = RouteTimings::new();
        for i in 0..1000 {
            let method = Method::from_bytes(format!("XQ{i:05}").as_bytes()).unwrap();
            timings.observe(method_label(&method), "/version".to_owned(), 0.01);
        }
        let snapshot = timings.snapshot();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].method, "OTHER");
        assert_eq!(snapshot[0].count, 1000);
    }

    #[test]
    fn a_fresh_handle_answers_no_series_at_all() {
        assert!(RouteTimings::new().snapshot().is_empty());
    }
}
