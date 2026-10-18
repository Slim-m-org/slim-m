// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A slow upstream ends inside the run: the module hears `net.fetch timed
//! out` in its own response instead of the caller seeing the whole module
//! time out, and a fetching module is given the wall clock to hear it.

use std::time::{Duration, Instant};

use axum::Router;
use axum::routing::get;
use serde_json::json;
use slimm_server::module_runtime::NET_FETCH_WALL_FLOOR_MS;

mod support;
use support::module_world::{Install, world};
use support::wasm_fixtures::host_call_loop_wasm;

#[tokio::test]
async fn a_slow_upstream_is_a_clean_timeout_in_the_modules_own_answer() {
    slimm_server::module_runtime::treat_loopback_as_lan_for_tests(true);
    let app = Router::new().route(
        "/slow",
        get(|| async {
            tokio::time::sleep(Duration::from_secs(30)).await;
            "late"
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let w = world("slimm-modnet-slow").await;
    let host = format!("127.0.0.1:{port}");
    let request = json!({ "capability": "net.fetch", "url": format!("http://{host}/slow") });
    w.install(Install {
        id: "slowpoke",
        wasm: host_call_loop_wasm(&request.to_string(), 1),
        declared: &["net.fetch"],
        approved_host: &["net.fetch"],
    })
    .await;
    w.store
        .set_module_network("slowpoke", &[host], true)
        .await
        .unwrap();

    let started = Instant::now();
    let answer = w.answer("slowpoke").await;
    assert!(answer.contains("net.fetch timed out"), "{answer}");
    assert!(
        started.elapsed() < Duration::from_millis(NET_FETCH_WALL_FLOOR_MS),
        "answered in {:?}, after the run's own wall clock",
        started.elapsed()
    );
}
