// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Event::MemberJoined` fires on every real join path: registration
//! (`POST /auth/register`) and an existing account spending an invite code
//! (`POST /invites/{code}/redeem`, over `Store::redeem_invite`). It does not
//! fire for a restore from `space_removals`, which already has its own
//! `Event::MemberRestored` and is not a new member; see `member_restored_event.rs`.
//! The `dm_open_publishes_no_event.rs` shape: subscribe to the hub directly
//! around the real route.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::hub::{Event, Hub};
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

fn app_with_hub(store: Store, hub: Hub) -> Router {
    support::app::builder(store).hub(hub).router()
}

async fn register(app: &Router, username: &str, invite_code: Option<&str>) -> StatusCode {
    let mut body = serde_json::json!({
        "username": username,
        "display_name": username,
        "password": "hunter2hunter2",
        "device_name": "cli",
    });
    if let Some(code) = invite_code {
        body["invite_code"] = serde_json::Value::String(code.to_owned());
    }
    app.clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/register")
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
}

async fn redeem(app: &Router, access_token: &str, code: &str) -> StatusCode {
    app.clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/invites/{code}/redeem"))
                .header("authorization", format!("Bearer {access_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
}

/// The first account claims an unclaimed deployment, which is still a real
/// join: it becomes the first member, and there is nobody else it could
/// possibly greet yet, but the event must still fire for the join paths that
/// come after it to have anything consistent to rely on.
#[tokio::test]
async fn registering_the_first_account_publishes_member_joined() {
    let (store, _guard) = support::new_store("slimm-member-joined").await;
    let hub = Hub::new();
    let app = app_with_hub(store, hub.clone());

    let mut rx = hub.subscribe();
    let status = register(&app, "alice", None).await;
    assert_eq!(status, StatusCode::OK);

    let mut joined = None;
    while let Ok(event) = rx.try_recv() {
        if let Event::MemberJoined(id) = event {
            joined = Some(id);
        }
    }
    assert!(
        joined.is_some(),
        "a fresh registration must publish MemberJoined"
    );
}

#[tokio::test]
async fn redeeming_an_invite_publishes_member_joined() {
    let (store, _guard) = support::new_store("slimm-member-joined").await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());

    let admin = store.create_account("admin", "Admin", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let invite = store
        .create_invite(admin.id, None, None, None)
        .await
        .unwrap();
    let bob = store.create_account("bob", "Bob", "x").await.unwrap();
    let bob_tokens = store.open_session(bob.id, "cli").await.unwrap();

    let mut rx = hub.subscribe();
    let status = redeem(&app, &bob_tokens.access_token, &invite.code).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let mut joined = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, Event::MemberJoined(id) if id == bob.id) {
            joined = true;
        }
    }
    assert!(joined, "a fresh redemption must publish MemberJoined");
}

/// The idempotent retry in `Store::redeem_invite` must not fan out a second
/// join announcement, or a greeter bot would greet the same member twice for
/// one flaky response.
#[tokio::test]
async fn a_retried_redemption_publishes_nothing_further() {
    let (store, _guard) = support::new_store("slimm-member-joined").await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());

    let admin = store.create_account("admin", "Admin", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let invite = store
        .create_invite(admin.id, None, None, None)
        .await
        .unwrap();
    let bob = store.create_account("bob", "Bob", "x").await.unwrap();
    let bob_tokens = store.open_session(bob.id, "cli").await.unwrap();

    let first = redeem(&app, &bob_tokens.access_token, &invite.code).await;
    assert_eq!(first, StatusCode::NO_CONTENT);

    let mut rx = hub.subscribe();
    let retry = redeem(&app, &bob_tokens.access_token, &invite.code).await;
    assert_eq!(retry, StatusCode::NO_CONTENT);
    assert!(
        rx.try_recv().is_err(),
        "a retried redemption must not publish MemberJoined again"
    );
}
