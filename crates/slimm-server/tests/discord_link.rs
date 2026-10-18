// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Linking a Discord account through the OAuth code flow, against a local
//! fake of Discord's token and identity endpoints.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::{get, post};
use axum::{Extension, Json, Router};
use serde_json::json;
use slimm_server::http::linked_accounts::DiscordLinks;
use slimm_server::http::{self, AppState};
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::json_body;

const REDIRECT: &str = "https://slim.example/links/discord/callback";

async fn fake_discord() -> String {
    let app = Router::new()
        .route(
            "/oauth2/token",
            post(|body: String| async move {
                assert!(body.contains("code=good-code"), "{body}");
                assert!(body.contains("grant_type=authorization_code"), "{body}");
                Json(json!({ "access_token": "fake-token", "token_type": "Bearer" }))
            }),
        )
        .route(
            "/users/@me",
            get(|| async {
                Json(
                    json!({ "id": "80351110224678912", "username": "ada", "global_name": "Ada L" }),
                )
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("http://{addr}")
}

fn state(store: Store) -> AppState {
    support::app::state(store)
}

async fn linked_app(store: Store) -> Router {
    let api = fake_discord().await;
    let discord = DiscordLinks::with_api("client-1", "secret-1", REDIRECT, &api).unwrap();
    http::router(state(store)).layer(Extension(discord))
}

fn authed(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

fn browser(uri: &str) -> Request<Body> {
    Request::builder().uri(uri).body(Body::empty()).unwrap()
}

/// Starts a link for `token` and hands back the state Discord would echo.
async fn start(app: &Router, token: &str) -> String {
    let response = app
        .clone()
        .oneshot(authed("POST", "/me/links/discord/start", token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let url = url::Url::parse(json_body(response).await["url"].as_str().unwrap()).unwrap();
    let pairs: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
    assert_eq!(url.host_str(), Some("discord.com"));
    assert_eq!(pairs["client_id"], "client-1");
    assert_eq!(pairs["scope"], "identify");
    assert_eq!(pairs["redirect_uri"], REDIRECT);
    pairs["state"].clone()
}

async fn callback(app: &Router, state: &str) -> StatusCode {
    app.clone()
        .oneshot(browser(&format!(
            "/links/discord/callback?code=good-code&state={state}"
        )))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn a_member_links_discord_and_others_see_it() {
    let (store, _guard) = support::new_store("slimm-discord-link").await;
    let ada = store.create_user("ada", "Ada").await.unwrap();
    let bob = store.create_user("bob", "Bob").await.unwrap();
    let ada_token = store
        .open_session(ada.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let bob_token = store
        .open_session(bob.id, "phone")
        .await
        .unwrap()
        .access_token;
    let app = linked_app(store).await;

    let state = start(&app, &ada_token).await;
    assert_eq!(callback(&app, &state).await, StatusCode::OK);

    let mine = app
        .clone()
        .oneshot(authed("GET", "/me/links", &ada_token))
        .await
        .unwrap();
    let mine = json_body(mine).await;
    assert_eq!(mine[0]["provider"], "discord");
    assert_eq!(mine[0]["username"], "ada");
    assert_eq!(mine[0]["display_name"], "Ada L");

    let seen = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/users/{}/links", ada.id),
            &bob_token,
        ))
        .await
        .unwrap();
    assert_eq!(json_body(seen).await[0]["username"], "ada");

    let unlinked = app
        .clone()
        .oneshot(authed("DELETE", "/me/links/discord", &ada_token))
        .await
        .unwrap();
    assert_eq!(unlinked.status(), StatusCode::NO_CONTENT);
    let after = app
        .oneshot(authed("GET", "/me/links", &ada_token))
        .await
        .unwrap();
    assert_eq!(json_body(after).await, json!([]));
}

#[tokio::test]
async fn a_state_works_once_and_a_forged_one_never() {
    let (store, _guard) = support::new_store("slimm-discord-state").await;
    let ada = store.create_user("ada", "Ada").await.unwrap();
    let token = store
        .open_session(ada.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let app = linked_app(store).await;

    let forged = "a".repeat(43);
    assert_eq!(callback(&app, &forged).await, StatusCode::BAD_REQUEST);

    let state = start(&app, &token).await;
    assert_eq!(callback(&app, &state).await, StatusCode::OK);
    assert_eq!(callback(&app, &state).await, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn one_discord_account_links_to_one_member() {
    let (store, _guard) = support::new_store("slimm-discord-taken").await;
    let ada = store.create_user("ada", "Ada").await.unwrap();
    let bob = store.create_user("bob", "Bob").await.unwrap();
    let ada_token = store
        .open_session(ada.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let bob_token = store
        .open_session(bob.id, "phone")
        .await
        .unwrap()
        .access_token;
    let app = linked_app(store).await;

    let first = start(&app, &ada_token).await;
    assert_eq!(callback(&app, &first).await, StatusCode::OK);
    let second = start(&app, &bob_token).await;
    assert_eq!(callback(&app, &second).await, StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_server_without_discord_says_so() {
    let (store, _guard) = support::new_store("slimm-discord-off").await;
    let ada = store.create_user("ada", "Ada").await.unwrap();
    let token = store
        .open_session(ada.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let app = http::router(state(store));

    let response = app
        .oneshot(authed("POST", "/me/links/discord/start", &token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
}
