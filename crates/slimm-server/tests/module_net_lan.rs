// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The second approval lifts private LAN ranges and nothing else. This binary
//! never turns on the loopback test seam, so loopback here is the real thing:
//! the slim server's own listener, which no approval may reach.

use axum::Router;
use axum::routing::get;
use serde_json::json;

mod support;
use support::module_world::{Install, world};
use support::wasm_fixtures::host_call_loop_wasm;

fn fetch(url: &str) -> String {
    json!({ "capability": "net.fetch", "url": url }).to_string()
}

async fn upstream() -> u16 {
    let app = Router::new().route("/status", get(|| async { "up" }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    port
}

#[tokio::test]
async fn local_approval_does_not_reach_loopback_or_the_metadata_address() {
    let w = world("slimm-modnet-lan-refused").await;
    let port = upstream().await;
    for (id, host, url) in [
        (
            "loop",
            format!("127.0.0.1:{port}"),
            format!("http://127.0.0.1:{port}/status"),
        ),
        (
            "name",
            format!("localhost:{port}"),
            format!("http://localhost:{port}/status"),
        ),
        (
            "v6",
            format!("::1:{port}"),
            format!("http://[::1]:{port}/status"),
        ),
        (
            "meta",
            "169.254.169.254".to_owned(),
            "http://169.254.169.254/latest/meta-data".to_owned(),
        ),
    ] {
        w.install(Install {
            id,
            wasm: host_call_loop_wasm(&fetch(&url), 1),
            declared: &["net.fetch"],
            approved_host: &["net.fetch"],
        })
        .await;
        w.store.set_module_network(id, &[host], true).await.unwrap();
        let answer = w.answer(id).await;
        assert!(answer.contains("'ok':false"), "{id}: {answer}");
        assert!(answer.contains("private network"), "{id}: {answer}");
    }
}
