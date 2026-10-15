// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `net.fetch` through the real command route: a module reaches only the
//! hosts an admin approved, and a local address only with the separate local
//! network approval. The upstream is a real listener on loopback, which is
//! exactly the local address the second approval exists for.

use axum::Router;
use axum::routing::get;
use serde_json::json;

mod support;
use support::module_world::{Install, world};
use support::wasm_fixtures::host_call_loop_wasm;

async fn upstream() -> u16 {
    let app = Router::new().route("/status", get(|| async { "up" }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    port
}

fn fetch(url: &str) -> String {
    json!({ "capability": "net.fetch", "url": url }).to_string()
}

#[tokio::test]
async fn an_approved_host_answers_only_with_the_local_approval() {
    let w = world("slimm-modnet-local").await;
    let port = upstream().await;
    let host = format!("localhost:{port}");
    w.install(Install {
        id: "status",
        wasm: host_call_loop_wasm(&fetch(&format!("http://{host}/status")), 1),
        declared: &["net.fetch"],
        approved_host: &["net.fetch"],
    })
    .await;

    w.store
        .set_module_network("status", std::slice::from_ref(&host), false)
        .await
        .unwrap();
    let refused = w.answer("status").await;
    assert!(refused.contains("local network approval"), "{refused}");

    w.store
        .set_module_network("status", &[host], true)
        .await
        .unwrap();
    let answered = w.answer("status").await;
    assert!(answered.contains("'ok':true"), "{answered}");
    assert!(answered.contains("'status':200"), "{answered}");
    assert!(answered.contains("'body':'up'"), "{answered}");
}

#[tokio::test]
async fn a_host_the_admin_did_not_approve_is_refused_before_dialling() {
    let w = world("slimm-modnet-unlisted").await;
    let port = upstream().await;
    w.install(Install {
        id: "sneaky",
        wasm: host_call_loop_wasm(&fetch(&format!("http://127.0.0.1:{port}/status")), 1),
        declared: &["net.fetch"],
        approved_host: &["net.fetch"],
    })
    .await;
    w.store
        .set_module_network("sneaky", &["api.example.com".to_owned()], true)
        .await
        .unwrap();
    let refused = w.answer("sneaky").await;
    assert!(
        refused.contains("host not approved for this module: 127.0.0.1"),
        "{refused}"
    );
}

#[tokio::test]
async fn net_fetch_declared_but_not_approved_reaches_nothing() {
    let w = world("slimm-modnet-unapproved").await;
    let port = upstream().await;
    w.install(Install {
        id: "hopeful",
        wasm: host_call_loop_wasm(&fetch(&format!("http://localhost:{port}/status")), 1),
        declared: &["net.fetch", "kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    w.store
        .set_module_network("hopeful", &[format!("localhost:{port}")], true)
        .await
        .unwrap();
    let refused = w.answer("hopeful").await;
    assert!(
        refused.contains("capability not approved: net.fetch"),
        "{refused}"
    );
}
