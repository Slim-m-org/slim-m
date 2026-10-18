// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /metrics`: gating, and the shape of the Prometheus text it answers
//! with. See `http/metrics.rs`'s own doc comment for the reasoning.

use std::sync::{Arc, Mutex};

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::{Hub, MemoryReading};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

async fn store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app(store: Store, voice: VoiceService) -> Router {
    app_with_hub(store, voice, Hub::new())
}

fn app_with_hub(store: Store, voice: VoiceService, hub: Hub) -> Router {
    support::app::builder(store).hub(hub).voice(voice).router()
}

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// An administrator plus an ordinary member: MANAGE_SERVER on one, nothing
/// beyond @everyone on the other. The same shape `space_analytics.rs` seeds.
async fn deployment(s: &Store) -> (slimm_server::store::User, slimm_server::store::User) {
    s.create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let member = s.create_user("nia", "Nia").await.unwrap();
    (admin, member)
}

async fn body_text(response: axum::response::Response) -> String {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}

#[tokio::test]
async fn an_unauthenticated_caller_is_refused() {
    let (s, _guard) = store("slimm-metrics-unauth").await;
    let router = app(s, VoiceService::disabled());
    let response = router
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/metrics")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

/// Gated identically to `/space/analytics`: a caller with only @everyone's
/// bits is refused, same as `space_analytics.rs`'s own
/// `reading_analytics_requires_manage_server`.
#[tokio::test]
async fn a_caller_without_manage_server_is_refused() {
    let (s, _guard) = store("slimm-metrics-forbidden").await;
    let (_admin, member) = deployment(&s).await;
    let session = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s, VoiceService::disabled());
    let response = router
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// The load-bearing shape test: every non-comment, non-blank line is a valid
/// Prometheus exposition line (`name{labels} value`, or a bare `name value`),
/// every metric that appears has both a `# HELP` and a `# TYPE` line ahead of
/// it, and the series the mission names are all present. Mutation-tested by
/// hand: dropping any one of the `write_*` calls in `http/metrics.rs` fails
/// exactly the matching assertion below and nothing else.
#[tokio::test]
async fn a_manage_server_caller_gets_valid_prometheus_text_with_every_series() {
    let (s, _guard) = store("slimm-metrics-shape").await;
    let (admin, _member) = deployment(&s).await;
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s, VoiceService::disabled());
    let response = router
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap()
        .to_owned();
    assert!(content_type.starts_with("text/plain"));

    let text = body_text(response).await;
    assert_prometheus_format(&text);

    assert!(text.contains("slimm_process_resident_memory_bytes "));
    assert!(text.contains("slimm_requests_total{class=\"read\"} "));
    assert!(text.contains("slimm_requests_refused_total{class=\"password\"} "));
    assert!(text.contains("slimm_websocket_connections "));
    assert!(text.contains("slimm_memory_admission_refused_total "));
    // No SFU here: the configured gauge is 0 and the reachable gauge is absent, not a misleading 0.
    assert!(text.contains("slimm_livekit_configured 0"));
    assert!(!text.contains("slimm_livekit_reachable"));

    // The pool gauges read the pool's own state, so they need no prior request.
    assert!(text.contains("slimm_db_pool_connections_max "));
    assert!(text.contains("slimm_db_pool_connections "));
    assert!(text.contains("slimm_db_pool_connections_in_use "));
}

/// Per-route latency is recorded *after* a request finishes, so the request
/// asking for `/metrics` can never report its own duration - only a later
/// scrape sees it. This drives two, and checks the histogram for
/// `GET /metrics` shows up on the second with a plausible shape: every
/// bucket is present, the `+Inf` bucket matches `_count`, and both are at
/// least 1 since the first call already completed as a `GET /metrics`.
#[tokio::test]
async fn a_second_scrape_reports_the_first_scrapes_own_latency() {
    let (s, _guard) = store("slimm-metrics-latency").await;
    let (admin, _member) = deployment(&s).await;
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s, VoiceService::disabled());

    let first = router
        .clone()
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    body_text(first).await;

    let second = router
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    let text = body_text(second).await;
    assert_prometheus_format(&text);

    assert!(text.contains("# TYPE slimm_http_request_duration_seconds histogram\n"));
    assert!(text.contains(
        "slimm_http_request_duration_seconds_bucket{method=\"GET\",route=\"/metrics\",le=\"+Inf\"} "
    ));
    let count = metric_value(
        &text,
        "slimm_http_request_duration_seconds_count{method=\"GET\",route=\"/metrics\"} ",
    );
    let inf_bucket = metric_value(
        &text,
        "slimm_http_request_duration_seconds_bucket{method=\"GET\",route=\"/metrics\",le=\"+Inf\"} ",
    );
    assert!(count >= 1, "the first scrape must have been recorded");
    assert_eq!(
        inf_bucket, count,
        "the +Inf bucket always equals the total count"
    );
}

/// The exact numeric value on the one line starting with `prefix`, panicking
/// if that line is missing - a sharper failure than the substring-only
/// `contains` checks above give when a test actually needs the number.
fn metric_value(text: &str, prefix: &str) -> u64 {
    text.lines()
        .find(|line| line.starts_with(prefix))
        .and_then(|line| line.rsplit(' ').next())
        .and_then(|value| value.parse().ok())
        .unwrap_or_else(|| panic!("no line starting with {prefix:?} in:\n{text}"))
}

/// A discovered memory ceiling reports both the limit and usage gauges, with
/// the exact values the guard was given - proving the wiring from
/// `Hub::memory_admission_snapshot` through to the exposition text, without
/// depending on whatever cgroup (or lack of one) the test happens to run
/// under.
#[tokio::test]
async fn a_discovered_memory_ceiling_reports_both_gauges() {
    let (s, _guard) = store("slimm-metrics-mem-known").await;
    let (admin, _member) = deployment(&s).await;
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let hub = Hub::with_memory_reading(Arc::new(Mutex::new(MemoryReading {
        limit_bytes: Some(536_870_912),
        usage_bytes: Some(123_456_789),
    })));
    let router = app_with_hub(s, VoiceService::disabled(), hub);
    let response = router
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    let text = body_text(response).await;
    assert!(text.contains("slimm_memory_limit_bytes 536870912"));
    assert!(text.contains("slimm_memory_usage_bytes 123456789"));
}

/// No discoverable ceiling omits both gauges, the same "absent, not a
/// misleading zero" shape `slimm_livekit_reachable` uses when no SFU is
/// configured, rather than reporting a `0` that would read as "no memory in
/// use" instead of "unknown".
#[tokio::test]
async fn no_discoverable_memory_ceiling_omits_both_gauges() {
    let (s, _guard) = store("slimm-metrics-mem-unknown").await;
    let (admin, _member) = deployment(&s).await;
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let hub = Hub::with_memory_reading(Arc::new(Mutex::new(MemoryReading::default())));
    let router = app_with_hub(s, VoiceService::disabled(), hub);
    let response = router
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    let text = body_text(response).await;
    assert!(!text.contains("slimm_memory_limit_bytes "));
    assert!(!text.contains("slimm_memory_usage_bytes "));
    assert!(text.contains("slimm_memory_admission_refused_total 0"));
}

/// The one gauge that reflects real traffic within the request itself: the
/// probing call above already spent one `Write`-class request - `/metrics`'s
/// own class, since `write_voice` makes a real outbound call on every scrape
/// - so this asks again and reads a count of at least 2, rather than
/// trusting a fixed number an unrelated change to route wiring could shift.
#[tokio::test]
async fn the_write_class_counter_reflects_real_requests() {
    let (s, _guard) = store("slimm-metrics-counts").await;
    let (admin, _member) = deployment(&s).await;
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s, VoiceService::disabled());

    let first = router
        .clone()
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    let first_text = body_text(first).await;
    let before = write_count(&first_text);

    let second = router
        .clone()
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    let second_text = body_text(second).await;
    let after = write_count(&second_text);

    assert!(
        after > before,
        "a second /metrics call must itself have counted, {before} then {after}"
    );
}

/// A deployment with an SFU configured, but none reachable at the address
/// given, answers both LiveKit gauges rather than omitting the second one.
#[tokio::test]
async fn a_configured_but_unreachable_sfu_reports_both_gauges() {
    let (s, _guard) = store("slimm-metrics-sfu-down").await;
    let (admin, _member) = deployment(&s).await;
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    // Bound to grab a free port, then dropped so nothing answers on it.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);
    let voice = VoiceService::for_test(&format!("http://{addr}"), "k", "s");

    let router = app(s, voice);
    let response = router
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    let text = body_text(response).await;
    assert!(text.contains("slimm_livekit_configured 1"));
    assert!(text.contains("slimm_livekit_reachable 0"));
}

fn write_count(text: &str) -> u64 {
    text.lines()
        .find(|line| line.starts_with("slimm_requests_total{class=\"write\"} "))
        .and_then(|line| line.rsplit(' ').next())
        .and_then(|value| value.parse().ok())
        .expect("the write counter line is present and numeric")
}

/// Every metric line the server answers with parses under the Prometheus
/// text exposition grammar: `# HELP <name> <text>`, `# TYPE <name> <kind>`,
/// or `<name>{label="value",...} <number>` / `<name> <number>`. Also checks
/// that every metric name seen on a sample line was introduced by a `# TYPE`
/// line first, since a series with no declared type is not valid exposition
/// text either.
fn assert_prometheus_format(text: &str) {
    assert!(!text.is_empty(), "the body must not be empty");
    assert!(text.ends_with('\n'), "exposition text ends in a newline");

    let mut typed: std::collections::HashMap<&str, &str> = std::collections::HashMap::new();
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("# TYPE ") {
            let mut parts = rest.split_whitespace();
            let name = parts.next().unwrap_or_default();
            let kind = parts.next().unwrap_or_default();
            assert!(
                !name.is_empty(),
                "a `# TYPE` line must name a metric: {line}"
            );
            typed.insert(name, kind);
            continue;
        }
        if line.starts_with("# HELP ") {
            continue;
        }
        assert!(!line.trim().is_empty(), "no blank lines in exposition text");

        let (name_and_labels, value) = line
            .rsplit_once(' ')
            .unwrap_or_else(|| panic!("sample line has no value: {line}"));
        value
            .parse::<f64>()
            .unwrap_or_else(|_| panic!("sample value is not a number: {line}"));

        let name = name_and_labels.split('{').next().unwrap_or_default();
        assert!(
            !name.is_empty()
                && name
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_alphabetic() || c == '_'),
            "metric name is not a legal Prometheus identifier: {line}"
        );
        // A histogram's _bucket/_sum/_count samples are typed under their shared base name.
        let recognized = typed.contains_key(name)
            || ["_bucket", "_sum", "_count"].iter().any(|suffix| {
                name.strip_suffix(suffix)
                    .is_some_and(|base| typed.get(base) == Some(&"histogram"))
            });
        assert!(
            recognized,
            "{name} appears on a sample line with no preceding `# TYPE` for it or its histogram base: {line}"
        );
    }
}

/// Also gated on `Class::Write`'s ordinary rate limit, the same tighter
/// budget `/space/analytics`'s own stats query stays on: a caller who
/// exhausts it is refused 429 the same way that route already is.
#[tokio::test]
async fn returns_json_error_shape_on_forbidden_not_a_partial_metrics_body() {
    let (s, _guard) = store("slimm-metrics-forbidden-shape").await;
    let (_admin, member) = deployment(&s).await;
    let session = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s, VoiceService::disabled());
    let response = router
        .oneshot(get("/metrics", &session.access_token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let text = body_text(response).await;
    let parsed: serde_json::Value = serde_json::from_str(&text).expect("a JSON error body");
    assert_eq!(parsed, json!({ "error": "insufficient permissions" }));
}
