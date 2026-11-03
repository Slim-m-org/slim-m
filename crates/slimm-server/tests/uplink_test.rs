// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin uplink test: the admin gate, the live-call refusal, the cooldown, the
//! kept history, and the measurement itself against a local endpoint (never the internet).

use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::http::StatusCode;
use axum::routing::post;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::uplink_test::measure;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_id as register, request_authed as request};

async fn harness(name: &str) -> (Store, support::TestDbGuard) {
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

/// A local stand-in for the speed endpoint; `slow` stalls after the first read.
async fn endpoint(slow: bool) -> String {
    let handler = move |body: Body| async move {
        let mut stream = body.into_data_stream();
        let mut seen = 0usize;
        use futures_util::StreamExt;
        while let Some(Ok(chunk)) = stream.next().await {
            seen += chunk.len();
            if slow {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
        seen.to_string()
    };
    let router = Router::new().route("/up", post(handler));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}/up")
}

#[tokio::test]
async fn measuring_a_local_endpoint_reports_the_whole_body() {
    let url = endpoint(false).await;
    let (mbit, bytes, _) = measure(&url, 4 * 1024 * 1024, Duration::from_secs(10))
        .await
        .unwrap();
    assert_eq!(bytes, 4 * 1024 * 1024);
    assert!(mbit > 0.0);
}

#[tokio::test]
async fn a_slow_endpoint_is_cut_off_at_the_limit() {
    let url = endpoint(true).await;
    let started = std::time::Instant::now();
    let (mbit, bytes, millis) = measure(&url, 400 * 1024 * 1024, Duration::from_millis(500))
        .await
        .unwrap();
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(bytes < 400 * 1024 * 1024 && bytes > 0);
    assert!(mbit > 0.0 && (400..2000).contains(&millis));
}

#[tokio::test]
async fn only_an_admin_may_run_or_read_it() {
    let (s, _guard) = harness("slimm-uplink-forbidden").await;
    let _admin = register(&s, "root").await;
    let member = s.create_user("nia", "Nia").await.unwrap();
    let session = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);
    for method in ["GET", "POST"] {
        let response = router
            .clone()
            .oneshot(request(
                method,
                "/space/uplink-test",
                &session.access_token,
                None,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN, "{method}");
    }
}

#[tokio::test]
async fn it_refuses_while_a_call_is_live() {
    let (s, _guard) = harness("slimm-uplink-live").await;
    let admin = register(&s, "root").await;
    let session = s.open_session(admin, "laptop").await.unwrap();
    let channel = s.create_channel("voice", "voice").await.unwrap().id;
    s.open_voice_session(channel, admin, "PA_1", 1_000)
        .await
        .unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(
            "POST",
            "/space/uplink-test",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_run_is_stored_audited_and_rate_limited() {
    let url = endpoint(false).await;
    // SAFETY: this binary's other tests never read this variable.
    unsafe { std::env::set_var("SLIMM_UPLINK_TEST_URL", url) };
    let (s, _guard) = harness("slimm-uplink-run").await;
    let admin = register(&s, "root").await;
    let session = s.open_session(admin, "laptop").await.unwrap();
    let router = app(s);
    let token = &session.access_token;

    let response = router
        .clone()
        .oneshot(request("POST", "/space/uplink-test", token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let run = json_body(response).await;
    assert_eq!(run["bytes"], json!(40 * 1024 * 1024));
    assert!(run["mbit_per_s"].as_f64().unwrap() > 0.0);

    let again = router
        .clone()
        .oneshot(request("POST", "/space/uplink-test", token, None))
        .await
        .unwrap();
    assert_eq!(again.status(), StatusCode::TOO_MANY_REQUESTS);

    let list = router
        .clone()
        .oneshot(request("GET", "/space/uplink-test", token, None))
        .await
        .unwrap();
    let list = json_body(list).await;
    assert_eq!(list["results"].as_array().unwrap().len(), 1);
    assert_eq!(list["results"][0]["id"], run["id"]);

    let log = router
        .oneshot(request("GET", "/space/audit-log", token, None))
        .await
        .unwrap();
    assert!(
        json_body(log)
            .await
            .to_string()
            .contains("space.uplink_test")
    );
}
