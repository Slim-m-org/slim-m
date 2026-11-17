// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A refused write names its reason with a stable `code` when the caller can
//! already see why: timed out (with when it lifts and the reason), blocked in a
//! DM, gone from a group they posted in, or pinning in a DM. A channel the
//! caller cannot see still gets the bare 403 a missing channel gets.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{app, json_body, register_id_token, request};

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

struct World {
    store: Store,
    app: Router,
    owner: UserId,
    bob: (UserId, String),
    carol: UserId,
    general: ChannelId,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-write-refusal").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ADD_REACTIONS),
            true,
        )
        .await
        .unwrap();
    let general = store.create_channel("general", "text").await.unwrap().id;
    let (owner, _) = register_id_token(&store, "owner").await;
    let bob = register_id_token(&store, "bob").await;
    let (carol, _) = register_id_token(&store, "carol").await;
    World {
        app: app(store.clone()),
        store,
        owner,
        bob,
        carol,
        general,
        _guard: guard,
    }
}

async fn call(w: &World, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
    let response = w
        .app
        .clone()
        .oneshot(request(method, uri, Some(&w.bob.1), body))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body(response).await)
}

async fn send_as_bob(w: &World, channel: ChannelId) -> (StatusCode, Value) {
    let body = json!({ "id": Uuid::now_v7().to_string(), "content": "hello" });
    call(
        w,
        "POST",
        &format!("/channels/{channel}/messages"),
        Some(body),
    )
    .await
}

#[tokio::test]
async fn a_timed_out_member_is_told_until_when_and_why() {
    let w = world().await;
    let until = now() + 60_000;
    w.store
        .set_member_timeout(w.bob.0, until, Some("cool off"), w.owner)
        .await
        .unwrap();

    let (status, body) = send_as_bob(&w, w.general).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["code"], "timed_out");
    assert_eq!(body["timed_out_until"], until);
    assert_eq!(body["timeout_reason"], "cool off");
}

#[tokio::test]
async fn a_channel_the_caller_cannot_see_stays_a_bare_refusal() {
    let w = world().await;
    let until = now() + 60_000;
    w.store
        .set_member_timeout(w.bob.0, until, None, w.owner)
        .await
        .unwrap();
    for channel in [ChannelId(Uuid::now_v7())] {
        let (status, body) = send_as_bob(&w, channel).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(body["error"], "insufficient permissions");
        assert!(body.get("code").is_none(), "{body}");
        assert!(body.get("timed_out_until").is_none(), "{body}");
    }
}

#[tokio::test]
async fn a_block_in_a_dm_says_so() {
    let w = world().await;
    let dm = w.store.open_dm(w.bob.0, w.carol).await.unwrap().id;
    w.store.block_user(w.carol, w.bob.0).await.unwrap();

    let (status, body) = send_as_bob(&w, dm).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["code"], "blocked");
}

#[tokio::test]
async fn leaving_a_group_you_posted_in_says_so_and_never_posting_does_not() {
    let w = world().await;
    let (group, _) = w
        .store
        .create_group_dm(w.owner, &[w.bob.0, w.carol], None, None)
        .await
        .unwrap();
    let (status, _) = send_as_bob(&w, group.id).await;
    assert_eq!(status, StatusCode::OK);
    w.store.leave_group_dm(w.bob.0, group.id).await.unwrap();

    let (status, body) = send_as_bob(&w, group.id).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["code"], "left_group");

    w.store.leave_group_dm(w.carol, group.id).await.unwrap();
    w.store
        .send_message(NewMessage::plain(
            group.id,
            w.owner,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap();
    let dave = support::app::register_token(&w.store, "dave").await;
    let response = w
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", group.id),
            Some(&dave),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "x" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(json_body(response).await.get("code").is_none());
}

#[tokio::test]
async fn pinning_in_a_dm_says_pins_are_not_available_there() {
    let w = world().await;
    let dm = w.store.open_dm(w.bob.0, w.carol).await.unwrap().id;
    let (_, sent) = send_as_bob(&w, dm).await;
    let uri = format!(
        "/channels/{dm}/messages/{}/pin",
        sent["id"].as_str().unwrap()
    );

    let (status, body) = call(&w, "PUT", &uri, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "dm_pins_unavailable");
}
