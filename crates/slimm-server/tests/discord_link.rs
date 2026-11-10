// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Linking a Discord account through the OAuth code flow, against a local
//! fake of Discord's token and identity endpoints. The callback only holds
//! the identity; the starter's own app finishes the link.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::{get, post};
use axum::{Extension, Json, Router};
use serde_json::json;
use slimm_server::http::linked_accounts::DiscordLinks;
use slimm_server::http::{self, AppState};
use slimm_server::store::{PendingLink, Store};
use tower::ServiceExt;

mod support;

use support::app::json_body;
use support::discord_link::{complete, handoff_in, text_body};

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

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
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

async fn callback_response(app: &Router, state: &str) -> axum::response::Response {
    app.clone()
        .oneshot(browser(&format!(
            "/links/discord/callback?code=good-code&state={state}"
        )))
        .await
        .unwrap()
}

async fn callback(app: &Router, state: &str) -> StatusCode {
    callback_response(app, state).await.status()
}

/// A full browser round trip for `token`'s link: the handoff its page shows.
async fn approve(app: &Router, token: &str) -> String {
    let state = start(app, token).await;
    let response = callback_response(app, &state).await;
    assert_eq!(response.status(), StatusCode::OK);
    handoff_in(&text_body(response).await)
}

async fn links_of(app: &Router, token: &str) -> serde_json::Value {
    let response = app
        .clone()
        .oneshot(authed("GET", "/me/links", token))
        .await
        .unwrap();
    json_body(response).await
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

    let handoff = approve(&app, &ada_token).await;
    assert_eq!(links_of(&app, &ada_token).await, json!([]));

    let finished = complete(&app, &ada_token, &handoff).await;
    assert_eq!(finished.status(), StatusCode::OK);
    assert_eq!(json_body(finished).await["username"], "ada");

    let mine = links_of(&app, &ada_token).await;
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
    assert_eq!(links_of(&app, &ada_token).await, json!([]));
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
async fn the_callback_alone_links_nothing() {
    let (store, _guard) = support::new_store("slimm-discord-callback-only").await;
    let ada = store.create_user("ada", "Ada").await.unwrap();
    let token = store
        .open_session(ada.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let app = linked_app(store.clone()).await;

    let state = start(&app, &token).await;
    let page = callback_response(&app, &state).await;
    let headers = page.headers().clone();
    let html = text_body(page).await;

    assert!(store.linked_accounts(ada.id).await.unwrap().is_empty());
    assert!(html.contains(&format!("slimm://discord-link?code={}", handoff_in(&html))));
    assert!(!html.contains(&state), "the page must not carry the state");
    assert!(
        headers["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("frame-ancestors 'none'")
    );
    assert_eq!(headers["cache-control"], "no-store");
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

    let first = approve(&app, &ada_token).await;
    assert_eq!(
        complete(&app, &ada_token, &first).await.status(),
        StatusCode::OK
    );
    let second = approve(&app, &bob_token).await;
    assert_eq!(
        complete(&app, &bob_token, &second).await.status(),
        StatusCode::CONFLICT
    );
    assert_eq!(links_of(&app, &bob_token).await, json!([]));
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

struct Pair {
    app: Router,
    store: Store,
    ada: slimm_server::ids::UserId,
    ada_token: String,
    bob_token: String,
    /// Bind it when destructuring: `..` drops it at once, which deletes the database under the pool.
    _guard: support::TestDbGuard,
}

async fn two_members(name: &str) -> Pair {
    let (store, guard) = support::new_store(name).await;
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
    Pair {
        app: linked_app(store.clone()).await,
        store,
        ada: ada.id,
        ada_token,
        bob_token,
        _guard: guard,
    }
}

#[tokio::test]
async fn only_the_member_who_started_the_link_can_finish_it() {
    let Pair {
        app,
        ada_token,
        bob_token,
        _guard,
        ..
    } = two_members("slimm-discord-bound").await;

    // Ada starts the link and gets someone else to approve it; the page is theirs.
    let handoff = approve(&app, &ada_token).await;

    let by_bob = complete(&app, &bob_token, &handoff).await;
    assert_eq!(by_bob.status(), StatusCode::NOT_FOUND);
    assert_eq!(links_of(&app, &bob_token).await, json!([]));
    assert_eq!(links_of(&app, &ada_token).await, json!([]));

    // Refusing dropped the pending link, so the right bearer cannot use it afterwards either.
    let by_ada = complete(&app, &ada_token, &handoff).await;
    assert_eq!(by_ada.status(), StatusCode::NOT_FOUND);
    assert_eq!(links_of(&app, &ada_token).await, json!([]));
}

#[tokio::test]
async fn the_state_the_starter_holds_is_not_a_handoff() {
    let Pair {
        app,
        ada_token,
        _guard,
        ..
    } = two_members("slimm-discord-state-key").await;

    let state = start(&app, &ada_token).await;
    assert_eq!(callback(&app, &state).await, StatusCode::OK);

    let response = complete(&app, &ada_token, &state).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert_eq!(links_of(&app, &ada_token).await, json!([]));
}

#[tokio::test]
async fn a_wrong_expired_or_spent_handoff_is_refused() {
    let Pair {
        app,
        store,
        ada,
        ada_token,
        _guard,
        ..
    } = two_members("slimm-discord-handoff").await;

    let wrong = complete(&app, &ada_token, "ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2").await;
    assert_eq!(wrong.status(), StatusCode::NOT_FOUND);
    let oversized = complete(&app, &ada_token, &"A".repeat(500)).await;
    assert_eq!(oversized.status(), StatusCode::NOT_FOUND);

    let pending = PendingLink {
        user_id: ada,
        external_id: "80351110224678912".to_owned(),
        username: "ada".to_owned(),
        display_name: None,
        avatar_hash: None,
    };
    let expired = store
        .create_link_handoff("discord", &pending, now_ms() - 1)
        .await
        .unwrap();
    let late = complete(&app, &ada_token, &expired).await;
    assert_eq!(late.status(), StatusCode::NOT_FOUND);

    let handoff = approve(&app, &ada_token).await;
    assert_eq!(
        complete(&app, &ada_token, &handoff).await.status(),
        StatusCode::OK
    );
    let again = complete(&app, &ada_token, &handoff).await;
    assert_eq!(again.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_pasted_code_may_carry_dashes_spaces_and_lower_case() {
    let Pair {
        app,
        ada_token,
        _guard,
        ..
    } = two_members("slimm-discord-paste").await;
    let handoff = approve(&app, &ada_token).await;
    let pasted = format!(
        " {}-{}-{}-{}-{} \n",
        &handoff[0..5],
        &handoff[5..10],
        &handoff[10..15],
        &handoff[15..20],
        &handoff[20..25]
    )
    .to_lowercase();

    let finished = complete(&app, &ada_token, &pasted).await;
    assert_eq!(finished.status(), StatusCode::OK);
}

#[tokio::test]
async fn finishing_a_link_needs_a_session() {
    let Pair {
        app,
        ada_token,
        _guard,
        ..
    } = two_members("slimm-discord-anon").await;
    let handoff = approve(&app, &ada_token).await;

    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/me/links/discord/complete")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "code": handoff }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        complete(&app, &ada_token, &handoff).await.status(),
        StatusCode::OK
    );
}
