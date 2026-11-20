// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A GIF picked for a screen stamp is a rendition the stamp route takes (decision 0121).
//!
//! The owner, 2026-11-20: "gifs not placing". The picker stored Klipy's `hd` file, 10.8 MB for
//! the GIF he chose, and the stamp route refuses a picture past 8 MiB, so no GIF that size ever
//! reached a screen. A pick for a stamp now takes the largest rendition a tile still animates.

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use serde_json::{Value, json};
use slimm_server::http::gifs::GifSearch;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tower::ServiceExt;

use crate::support;
use support::app::json_body;

/// Klipy's own full file for the owner's pick weighed 10.8 MB, past the stamp route's 8 MiB.
const HD_BYTES: usize = 10_854_357;
const MD_BYTES: usize = 900_000;
const XS_BYTES: usize = 40_000;

fn gif_of(len: usize) -> Vec<u8> {
    let mut bytes = b"GIF89a".to_vec();
    bytes.resize(len, 0);
    bytes
}

/// Shaped like a real captured Klipy search: each tier reports its own size.
async fn search(State(base): State<String>) -> axum::Json<Value> {
    let tier = |name: &str, side: u32, size: usize| json!({"gif": {"url": format!("{base}/{name}.gif"), "width": side, "height": side, "size": size}});
    axum::Json(json!({
        "result": true,
        "data": {"data": [{
            "id": 1,
            "title": "happy friday dance",
            "file": {
                "hd": tier("hd", 498, HD_BYTES),
                "md": tier("md", 320, MD_BYTES),
                "xs": tier("xs", 90, XS_BYTES),
            }
        }]}
    }))
}

async fn spawn_fake_klipy() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let router = Router::new()
        .route("/api/v1/{key}/gifs/search", get(search))
        .route("/hd.gif", get(|| async { gif_of(HD_BYTES) }))
        .route("/md.gif", get(|| async { gif_of(MD_BYTES) }))
        .route("/xs.gif", get(|| async { gif_of(XS_BYTES) }))
        .with_state(base.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    base
}

fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json");
    builder
        .body(body.map_or_else(Body::empty, |b| Body::from(b.to_string())))
        .unwrap()
}

async fn picked_size(app: &Router, token: &str, select: Value) -> u64 {
    let response = app
        .clone()
        .oneshot(request("POST", "/gifs/select", token, Some(select)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    json_body(response).await["size"].as_u64().unwrap()
}

async fn first_result(app: &Router, token: &str) -> String {
    let response = app
        .clone()
        .oneshot(request("GET", "/gifs/search?q=friday", token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await["results"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn signed_in(store: &Store) -> String {
    let account = store.create_account("alice", "alice", "x").await.unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

#[tokio::test]
async fn a_gif_picked_for_a_stamp_is_one_a_tile_animates() {
    let base = spawn_fake_klipy().await;
    let (store, _guard) = support::new_store("slimm-gif-stamp-test").await;
    let app = support::app::builder(store.clone())
        .gifs(GifSearch::for_test("klipy", &base, "test-key"))
        .router();
    let token = signed_in(&store).await;

    let id = first_result(&app, &token).await;
    let stamp = picked_size(&app, &token, json!({"id": id, "for_stamp": true})).await;
    assert_eq!(stamp, MD_BYTES as u64, "the largest rendition under 4 MiB");

    let message = picked_size(&app, &token, json!({"id": id})).await;
    assert_eq!(
        message, HD_BYTES as u64,
        "a message still gets the full file"
    );
}
