// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A block outlives the blocked account: once they delete it, the blocker
//! still hides what they left behind, while everyone else sees no author.

use serde_json::Value;
use slimm_server::ids::{CanvasObjectId, ChannelId, MessageId, UserId};
use slimm_server::store::{NewMessage, PlaceRequest, Store};
use tower::ServiceExt;

use crate::support;
use support::app::{json_body, request_authed};

struct World {
    app: axum::Router,
    store: Store,
    pool: sqlx::SqlitePool,
    channel: ChannelId,
    blocker: (UserId, String),
    bystander: String,
    leaver: UserId,
}

async fn world(store: Store, pool: sqlx::SqlitePool) -> World {
    let admin = store.create_account("root", "Root", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let blocker = store.create_account("ann", "Ann", "x").await.unwrap();
    let leaver = store.create_account("ben", "Ben", "x").await.unwrap();
    let token = |id| {
        let store = store.clone();
        async move { store.open_session(id, "cli").await.unwrap().access_token }
    };
    World {
        app: support::app::builder(store.clone()).router(),
        channel,
        blocker: (blocker.id, token(blocker.id).await),
        bystander: token(admin.id).await,
        leaver: leaver.id,
        store,
        pool,
    }
}

async fn get(app: &axum::Router, uri: &str, token: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request_authed("GET", uri, token, None))
        .await
        .unwrap();
    assert!(
        response.status().is_success(),
        "{uri}: {}",
        response.status()
    );
    json_body(response).await
}

async fn message_author(w: &World, token: &str, id: MessageId) -> Value {
    let page = get(&w.app, &format!("/channels/{}/messages", w.channel), token).await;
    let messages = page.as_array().or(page["messages"].as_array()).cloned();
    messages
        .expect("a page of messages")
        .into_iter()
        .find(|m| m["id"] == id.to_string())
        .expect("the message is listed")["author_id"]
        .clone()
}

async fn canvas_author(w: &World, token: &str, id: CanvasObjectId) -> Value {
    let uri = format!(
        "/channels/{}/canvas/objects?min_x=-10&min_y=-10&max_x=10&max_y=10",
        w.channel
    );
    let view = get(&w.app, &uri, token).await;
    view["objects"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["id"] == id.to_string())
        .expect("the object is in view")["author_id"]
        .clone()
}

async fn seed_content(w: &World) -> (MessageId, CanvasObjectId) {
    let message = MessageId::generate();
    w.store
        .send_message(NewMessage::plain(w.channel, w.leaver, message, "hello"))
        .await
        .unwrap();
    let object = CanvasObjectId::generate();
    w.store
        .place_canvas_object(
            w.channel,
            w.leaver,
            object,
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 1.0, 1.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .unwrap();
    (message, object)
}

#[tokio::test]
async fn a_blocker_still_hides_a_deleted_members_content() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-deletion-blocks").await;
    let w = world(store, pool).await;
    let (message, object) = seed_content(&w).await;
    w.store.block_user(w.blocker.0, w.leaver).await.unwrap();

    w.store.delete_account(w.leaver).await.unwrap();

    let blocks = get(&w.app, "/blocks", &w.blocker.1).await;
    assert!(
        blocks.to_string().contains(&w.leaver.to_string()),
        "the blocker's list still names the deleted account: {blocks}"
    );
    let leaver = Value::String(w.leaver.to_string());
    assert_eq!(message_author(&w, &w.blocker.1, message).await, leaver);
    assert_eq!(canvas_author(&w, &w.blocker.1, object).await, leaver);
    assert_eq!(message_author(&w, &w.bystander, message).await, Value::Null);
    assert_eq!(canvas_author(&w, &w.bystander, object).await, Value::Null);
}

#[tokio::test]
async fn unblocking_a_deleted_member_forgets_their_authorship() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-deletion-unblock").await;
    let w = world(store, pool).await;
    let (message, object) = seed_content(&w).await;
    w.store.block_user(w.blocker.0, w.leaver).await.unwrap();
    w.store.delete_account(w.leaver).await.unwrap();

    w.store.unblock_user(w.blocker.0, w.leaver).await.unwrap();

    assert_eq!(message_author(&w, &w.blocker.1, message).await, Value::Null);
    assert_eq!(canvas_author(&w, &w.blocker.1, object).await, Value::Null);
    let kept: i64 = sqlx::query_scalar(
        "SELECT (SELECT COUNT(*) FROM blocked_author_messages)
              + (SELECT COUNT(*) FROM blocked_author_canvas_objects)",
    )
    .fetch_one(&w.pool)
    .await
    .unwrap();
    assert_eq!(kept, 0, "nobody blocks them any more, so nothing is kept");
}

#[tokio::test]
async fn an_unblocked_deleted_members_authorship_is_never_kept() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-deletion-no-blocker").await;
    let w = world(store, pool).await;
    seed_content(&w).await;

    w.store.delete_account(w.leaver).await.unwrap();

    let kept: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM blocked_author_messages")
        .fetch_one(&w.pool)
        .await
        .unwrap();
    assert_eq!(kept, 0);
}
