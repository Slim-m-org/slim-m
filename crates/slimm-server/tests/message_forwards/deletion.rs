// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A forwarded copy follows its original out: deleting or ageing out the
//! original removes every copy, in every channel it was forwarded into.

use super::fixtures::*;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::{ChannelId, MessageId};
use tower::ServiceExt;
use uuid::Uuid;

fn message_id(value: &Value) -> MessageId {
    MessageId(Uuid::parse_str(value["id"].as_str().unwrap()).unwrap())
}

struct Forwarded {
    original: Value,
    /// A forward with nothing of its own, in another channel.
    bare: Value,
    /// A forward carrying the forwarder's own note, in the original's channel.
    noted: Value,
    general: String,
    other: String,
    channel: ChannelId,
}

async fn original_with_two_copies(
    app: &axum::Router,
    store: &slimm_server::store::Store,
    general: ChannelId,
    token: &str,
) -> Forwarded {
    let channel = general;
    let general = general.to_string();
    let other = store
        .create_channel("other", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let original = send(app, &general, token, "abusive text").await;
    let noted = json_body(
        post(
            app,
            &general,
            token,
            forward_body("my own words", &original),
        )
        .await,
    )
    .await;
    let bare = json_body(post(app, &other, token, forward_body("", &original)).await).await;
    Forwarded {
        original,
        bare,
        noted,
        general,
        other,
        channel,
    }
}

async fn listed(app: &axum::Router, channel: &str, token: &str) -> Vec<Value> {
    let uri = format!("/channels/{channel}/messages");
    let page = json_body(
        app.clone()
            .oneshot(request("GET", &uri, token, None))
            .await
            .unwrap(),
    )
    .await;
    page.as_array().unwrap().clone()
}

/// The bare copy is gone; the noted one stays with its words and no snapshot.
async fn assert_cold_reads(app: &axum::Router, f: &Forwarded, token: &str) {
    let other = listed(app, &f.other, token).await;
    assert!(
        !other.iter().any(|m| m["id"] == f.bare["id"]),
        "a bare copy is removed"
    );
    let general = listed(app, &f.general, token).await;
    let kept = general
        .iter()
        .find(|m| m["id"] == f.noted["id"])
        .expect("a copy with a note stays");
    assert_eq!(kept["content"], "my own words");
    assert_eq!(kept["forwarded"]["removed"], true);
    assert_eq!(kept["forwarded"]["content"], "");
    assert!(kept["forwarded"]["author_id"].is_null());
}

/// Sync agrees: the noted copy has an edit op flagged removed, the bare one a delete.
async fn assert_ops(store: &slimm_server::store::Store, f: &Forwarded) {
    let noted_id = message_id(&f.noted);
    let page = store.message_ops_since(f.channel, 0, 100).await.unwrap();
    let op = page
        .ops
        .iter()
        .find(|o| o.message_id == noted_id && o.forwarded_removed)
        .expect("an edit op says the snapshot is gone");
    assert_eq!(op.content.as_deref(), Some("my own words"));
}

#[tokio::test]
async fn deleting_the_original_follows_into_its_copies() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());
    let f = original_with_two_copies(&app, &store, channel, &token).await;

    let mut rx = hub.subscribe();
    let uri = format!(
        "/channels/{}/messages/{}",
        f.general,
        f.original["id"].as_str().unwrap()
    );
    let deleted = app
        .clone()
        .oneshot(request("DELETE", &uri, &token, None))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let (mut bare_deleted, mut noted_edited) = (false, false);
    while let Ok(event) = rx.try_recv() {
        match event {
            Event::MessageDeleted {
                channel_id,
                message_id: m,
                op_seq,
            } if m == message_id(&f.bare) => {
                assert_eq!(channel_id.to_string(), f.other);
                assert!(op_seq.is_some());
                bare_deleted = true;
            }
            Event::MessageEdited {
                message,
                forwarded,
                op_seq,
                ..
            } if message.id == message_id(&f.noted) => {
                assert_eq!(message.content, "my own words");
                assert!(forwarded.expect("the frame carries the marker").removed);
                assert!(op_seq > 0);
                noted_edited = true;
            }
            _ => {}
        }
    }
    assert!(bare_deleted, "the bare copy's channel hears a delete");
    assert!(noted_edited, "the noted copy's channel hears an edit");
    assert_cold_reads(&app, &f, &token).await;
    assert_ops(&store, &f).await;
}

#[tokio::test]
async fn a_bulk_delete_of_the_original_follows_into_its_copies() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let f = original_with_two_copies(&app, &store, channel, &token).await;

    let uri = format!("/channels/{}/messages/bulk-delete", f.general);
    let body = json!({ "message_ids": [f.original["id"]] });
    let status = app
        .clone()
        .oneshot(request("POST", &uri, &token, Some(body)))
        .await
        .unwrap()
        .status();
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_cold_reads(&app, &f, &token).await;
    assert_ops(&store, &f).await;
}

#[tokio::test]
async fn ageing_out_the_original_follows_into_its_copies() {
    let (store, pool, _guard) = new_store_with_pool().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let f = original_with_two_copies(&app, &store, channel, &token).await;

    store.set_message_retention_days(1).await.unwrap();
    sqlx::query("UPDATE messages SET created_at = 1000 WHERE id = ?")
        .bind(message_id(&f.original))
        .execute(&pool)
        .await
        .unwrap();

    let swept = store.sweep_message_retention().await.unwrap();
    let pruned: Vec<MessageId> = swept.pruned.iter().map(|p| p.message_id).collect();
    assert!(pruned.contains(&message_id(&f.original)));
    assert!(pruned.contains(&message_id(&f.bare)));
    assert!(!pruned.contains(&message_id(&f.noted)));
    assert!(
        swept
            .detached
            .iter()
            .any(|d| d.message_id == message_id(&f.noted))
    );
    assert_cold_reads(&app, &f, &token).await;
    assert_ops(&store, &f).await;

    let again = store.sweep_message_retention().await.unwrap();
    assert!(
        again.detached.is_empty(),
        "a detached copy is not swept twice"
    );
}

/// The access half of the snapshot stays: an edit does not reach a copy.
#[tokio::test]
async fn editing_the_original_leaves_the_copy_as_forwarded() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let general = channel.to_string();
    let original = send(&app, &general, &token, "as it was").await;
    let forward = json_body(post(&app, &general, &token, forward_body("", &original)).await).await;
    let uri = format!(
        "/channels/{general}/messages/{}",
        original["id"].as_str().unwrap()
    );
    let edited = app
        .clone()
        .oneshot(request(
            "PATCH",
            &uri,
            &token,
            Some(json!({ "content": "rewritten after the fact" })),
        ))
        .await
        .unwrap();
    assert_eq!(edited.status(), StatusCode::OK);
    let page = listed(&app, &general, &token).await;
    let copy = page.iter().find(|m| m["id"] == forward["id"]).unwrap();
    assert_eq!(copy["forwarded"]["content"], "as it was");
    assert_eq!(copy["forwarded"]["removed"], false);
}
