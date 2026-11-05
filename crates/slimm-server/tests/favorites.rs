// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Favorites: GIFs and message media kept in one private, ordered list.

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use serde_json::{Value, json};
use slimm_server::http::gifs::GifSearch;
use slimm_server::ids::{FavoriteId, UserId};
use slimm_server::store::{FavoriteError, MAX_FAVORITES, NewFavorite, Store};
use tokio::net::TcpListener;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::json_body;

fn req(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(b) => builder
            .header("content-type", "application/json")
            .body(Body::from(b.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

async fn tenor_search(State(base): State<String>) -> axum::Json<Value> {
    let hit = |n: u32| {
        json!({
            "id": format!("fake-{n}"),
            "content_description": format!("gif number {n}"),
            "media_formats": {
                "tinygif": {"url": format!("{base}/preview{n}.gif"), "dims": [220, 165], "size": 1},
                "gif": {"url": format!("{base}/full{n}.gif"), "dims": [498, 373], "size": 2}
            }
        })
    };
    axum::Json(json!({ "next": "", "results": [hit(1), hit(2)] }))
}

async fn gif_body() -> Vec<u8> {
    let mut bytes = b"GIF89a".to_vec();
    bytes.extend([7u8; 16]);
    bytes
}

async fn spawn_fake_tenor() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let router = Router::new()
        .route("/v2/search", get(tenor_search))
        .route("/preview1.gif", get(gif_body))
        .route("/full1.gif", get(gif_body))
        .route("/preview2.gif", get(gif_body))
        .route("/full2.gif", get(gif_body))
        .with_state(base.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    base
}

async fn rig(prefix: &str) -> (Router, Store, support::TestDbGuard) {
    let base = spawn_fake_tenor().await;
    let (store, guard) = support::new_store(prefix).await;
    let app = support::app::builder(store.clone())
        .gifs(GifSearch::for_test("tenor", &base, "k"))
        .router();
    (app, store, guard)
}

async fn call(app: &Router, r: Request<Body>) -> (StatusCode, Value) {
    let response = app.clone().oneshot(r).await.unwrap();
    let status = response.status();
    let body = if status == StatusCode::NO_CONTENT {
        Value::Null
    } else {
        json_body(response).await
    };
    (status, body)
}

async fn search_ids(app: &Router, token: &str) -> Vec<String> {
    let (_, body) = call(app, req("GET", "/gifs/search?q=cat", token, None)).await;
    body["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_str().unwrap().to_owned())
        .collect()
}

async fn add_gif(app: &Router, token: &str, gif_id: &str) -> (StatusCode, Value) {
    let body = json!({"id": Uuid::now_v7().to_string(), "kind": "gif", "gif_id": gif_id});
    call(app, req("POST", "/favorites", token, Some(body))).await
}

async fn list(app: &Router, token: &str) -> Vec<Value> {
    let (status, body) = call(app, req("GET", "/favorites", token, None)).await;
    assert_eq!(status, StatusCode::OK);
    body.as_array().unwrap().clone()
}

#[tokio::test]
async fn a_gif_favorite_survives_its_token_previews_and_sends() {
    let (app, store, _guard) = rig("slimm-fav-gif").await;
    let (token, _) = register(&store, "alice").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let ids = search_ids(&app, &token).await;

    let (status, first) = add_gif(&app, &token, &ids[0]).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(first["kind"], "gif");
    assert_eq!(first["title"], "gif number 1");
    assert_eq!(first["available"], true);
    assert!(
        first.get("attachment_id").is_none(),
        "no provider url or token leaks"
    );

    // Favoriting the same GIF again from a fresh search keeps one entry.
    let again = search_ids(&app, &token).await;
    let (_, dup) = add_gif(&app, &token, &again[0]).await;
    assert_eq!(dup["id"], first["id"]);
    let (_, second) = add_gif(&app, &token, &ids[1]).await;
    let fav_id = first["id"].as_str().unwrap();

    let rows = list(&app, &token).await;
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["id"], second["id"], "newest favorite goes first");

    let uri = format!("/favorites/{fav_id}/preview");
    let preview = app
        .clone()
        .oneshot(req("GET", &uri, &token, None))
        .await
        .unwrap();
    assert_eq!(preview.status(), StatusCode::OK);
    assert_eq!(preview.headers().get("content-type").unwrap(), "image/gif");

    let uri = format!("/favorites/{fav_id}/select");
    let (status, attachment) = call(&app, req("POST", &uri, &token, Some(json!({})))).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(attachment["content_type"], "image/gif");
    let send = json!({
        "id": Uuid::now_v7().to_string(), "content": "",
        "attachment_ids": [attachment["id"]],
    });
    let uri = format!("/channels/{}/messages", channel.id);
    let (status, _) = call(&app, req("POST", &uri, &token, Some(send))).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn reorder_moves_named_entries_first_and_keeps_the_rest() {
    let (app, store, _guard) = rig("slimm-fav-order").await;
    let (token, _) = register(&store, "alice").await;
    let ids = search_ids(&app, &token).await;
    let (_, a) = add_gif(&app, &token, &ids[0]).await;
    let (_, b) = add_gif(&app, &token, &ids[1]).await;
    // Newest first: [b, a]. Naming only a puts it ahead and b stays after.
    let body = json!({"ids": [a["id"]]});
    let (status, _) = call(&app, req("PUT", "/favorites/order", &token, Some(body))).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let rows = list(&app, &token).await;
    assert_eq!((&rows[0]["id"], &rows[1]["id"]), (&a["id"], &b["id"]));

    let uri = format!("/favorites/{}", a["id"].as_str().unwrap());
    let (status, _) = call(&app, req("DELETE", &uri, &token, None)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(list(&app, &token).await.len(), 1);
}

#[tokio::test]
async fn a_list_is_private_and_another_accounts_entry_is_missing() {
    let (app, store, _guard) = rig("slimm-fav-private").await;
    let (alice, _) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    let ids = search_ids(&app, &alice).await;
    let (_, mine) = add_gif(&app, &alice, &ids[0]).await;
    assert!(list(&app, &bob).await.is_empty());
    let uri = format!("/favorites/{}/select", mine["id"].as_str().unwrap());
    let (status, _) = call(&app, req("POST", &uri, &bob, Some(json!({})))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn an_attachment_favorite_is_a_reference_that_fails_gracefully_when_the_source_goes() {
    let (app, store, _guard) = rig("slimm-fav-attach").await;
    let (alice, _) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let ids = search_ids(&app, &alice).await;
    let (_, picked) = call(
        &app,
        req("POST", "/gifs/select", &alice, Some(json!({"id": ids[0]}))),
    )
    .await;
    let message_id = Uuid::now_v7().to_string();
    let send = json!({"id": message_id, "content": "", "attachment_ids": [picked["id"]]});
    let uri = format!("/channels/{}/messages", channel.id);
    call(&app, req("POST", &uri, &alice, Some(send))).await;

    // A file the message does not carry is refused.
    let wrong = json!({"id": Uuid::now_v7().to_string(), "kind": "attachment",
        "message_id": message_id, "attachment_id": "ab".repeat(32)});
    let (status, _) = call(&app, req("POST", "/favorites", &bob, Some(wrong))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let add = json!({"id": Uuid::now_v7().to_string(), "kind": "attachment",
        "message_id": message_id, "attachment_id": picked["id"]});
    let (status, fav) = call(&app, req("POST", "/favorites", &bob, Some(add))).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(fav["available"], true);
    assert_eq!(fav["attachment_id"], picked["id"]);
    assert_eq!(fav["channel_id"], channel.id.to_string());

    let sel = format!("/favorites/{}/select", fav["id"].as_str().unwrap());
    let (status, got) = call(&app, req("POST", &sel, &bob, Some(json!({})))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(got["id"], picked["id"]);

    let del = format!("/channels/{}/messages/{message_id}", channel.id);
    let (status, _) = call(&app, req("DELETE", &del, &alice, None)).await;
    assert!(status.is_success(), "deleting the source message: {status}");

    let rows = list(&app, &bob).await;
    assert_eq!(rows.len(), 1, "the entry stays so its owner can remove it");
    assert_eq!(rows[0]["available"], false);
    assert!(rows[0].get("message_id").is_none());
    let (status, _) = call(&app, req("POST", &sel, &bob, Some(json!({})))).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn the_list_holds_at_most_the_ceiling() {
    let (store, _guard) = support::new_store("slimm-fav-cap").await;
    let (_, user) = register(&store, "alice").await;
    let gif = |n: i64| NewFavorite::Gif {
        title: String::new(),
        width: 1,
        height: 1,
        preview_url: format!("http://x/p{n}"),
        full_url: format!("http://x/f{n}"),
    };
    for n in 0..MAX_FAVORITES {
        store
            .add_favorite(user, FavoriteId::generate(), &gif(n))
            .await
            .unwrap();
    }
    let over = store
        .add_favorite(user, FavoriteId::generate(), &gif(-1))
        .await;
    assert!(matches!(over, Err(FavoriteError::TooMany)));
    let held = store
        .add_favorite(user, FavoriteId::generate(), &gif(0))
        .await;
    assert!(
        held.is_ok(),
        "re-adding something already held is not refused"
    );
}
