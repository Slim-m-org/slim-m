// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /read-states` answers the caller's own marker in every channel they
//! can read, and matches what the per-channel route says for each one.

use std::collections::HashMap;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self};
use slimm_server::ids::{ChannelId, MessageId, RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

struct Fixture {
    store: Store,
    app: Router,
    everyone: RoleId,
    _guard: support::TestDbGuard,
}

struct Account {
    id: UserId,
    token: String,
}

async fn setup() -> Fixture {
    let (path, guard) = support::TestDbGuard::new("slimm-read-states");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let app = http::router(support::app::state(store.clone()));
    Fixture {
        store,
        app,
        everyone,
        _guard: guard,
    }
}

impl Fixture {
    async fn account(&self, name: &str) -> Account {
        let user = self.store.create_user(name, name).await.unwrap();
        let tokens = self.store.open_session(user.id, "dev").await.unwrap();
        Account {
            id: user.id,
            token: tokens.access_token,
        }
    }

    async fn post(&self, channel: ChannelId, author: &Account, count: usize) {
        for i in 0..count {
            self.store
                .send_message(NewMessage::plain(
                    channel,
                    author.id,
                    MessageId::generate(),
                    &format!("m{i}"),
                ))
                .await
                .unwrap();
        }
    }

    async fn get(&self, uri: &str, who: &Account) -> (StatusCode, Value) {
        let request = Request::builder()
            .method("GET")
            .uri(uri)
            .header("authorization", format!("Bearer {}", who.token))
            .body(Body::empty())
            .unwrap();
        let response = self.app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn put(&self, uri: &str, who: &Account, body: Option<Value>) {
        let builder = Request::builder()
            .method("PUT")
            .uri(uri)
            .header("authorization", format!("Bearer {}", who.token));
        let request = match body {
            Some(value) => builder
                .header("content-type", "application/json")
                .body(Body::from(value.to_string())),
            None => builder.body(Body::empty()),
        }
        .unwrap();
        let response = self.app.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    async fn read_states(&self, who: &Account) -> HashMap<String, Value> {
        let (status, body) = self.get("/read-states", who).await;
        assert_eq!(status, StatusCode::OK);
        body.as_array()
            .unwrap()
            .iter()
            .map(|row| (row["channel_id"].as_str().unwrap().to_string(), row.clone()))
            .collect()
    }
}

#[tokio::test]
async fn matches_the_per_channel_route_for_every_channel() {
    let f = setup().await;
    let alice = f.account("alice").await;
    let bob = f.account("bob").await;
    let opened = f.store.create_channel("opened", "text").await.unwrap();
    let marked = f.store.create_channel("marked", "text").await.unwrap();
    let untouched = f.store.create_channel("untouched", "text").await.unwrap();
    f.post(opened.id, &bob, 4).await;
    f.post(marked.id, &bob, 2).await;
    f.post(untouched.id, &bob, 3).await;
    f.put(
        &format!("/channels/{}/read", opened.id),
        &alice,
        Some(json!({ "seq": 3 })),
    )
    .await;
    f.put(&format!("/channels/{}/unread", marked.id), &alice, None)
        .await;

    let batch = f.read_states(&alice).await;
    assert_eq!(batch.len(), 3);
    for channel in [&opened, &marked, &untouched] {
        let (status, single) = f
            .get(&format!("/channels/{}/read", channel.id), &alice)
            .await;
        assert_eq!(status, StatusCode::OK);
        let row = &batch[&channel.id.to_string()];
        assert_eq!(
            row["last_read_seq"], single["last_read_seq"],
            "{}",
            channel.name
        );
        assert_eq!(row["unread"], single["unread"], "{}", channel.name);
        assert_eq!(
            row["manually_unread"], single["manually_unread"],
            "{}",
            channel.name
        );
    }
    assert_eq!(batch[&opened.id.to_string()]["last_read_seq"], 3);
    assert_eq!(batch[&opened.id.to_string()]["unread"], 1);
    assert_eq!(batch[&marked.id.to_string()]["manually_unread"], true);
    assert_eq!(batch[&untouched.id.to_string()]["unread"], 3);
}

#[tokio::test]
async fn carries_only_the_callers_own_markers() {
    let f = setup().await;
    let alice = f.account("alice").await;
    let bob = f.account("bob").await;
    let channel = f.store.create_channel("general", "text").await.unwrap();
    f.post(channel.id, &alice, 5).await;
    f.put(
        &format!("/channels/{}/read", channel.id),
        &bob,
        Some(json!({ "seq": 5 })),
    )
    .await;
    f.put(&format!("/channels/{}/unread", channel.id), &alice, None)
        .await;

    let mine = f.read_states(&alice).await[&channel.id.to_string()].clone();
    assert_eq!(mine["last_read_seq"], 0);
    assert_eq!(mine["unread"], 5);
    assert_eq!(mine["manually_unread"], true);
    let theirs = f.read_states(&bob).await[&channel.id.to_string()].clone();
    assert_eq!(theirs["last_read_seq"], 5);
    assert_eq!(theirs["unread"], 0);
    assert_eq!(theirs["manually_unread"], false);
}

#[tokio::test]
async fn omits_a_channel_the_caller_cannot_see() {
    let f = setup().await;
    let alice = f.account("alice").await;
    let bob = f.account("bob").await;
    let open = f.store.create_channel("open", "text").await.unwrap();
    let secret = f.store.create_channel("secret", "text").await.unwrap();
    f.store
        .set_role_overwrite(
            secret.id,
            f.everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    f.store
        .set_member_overwrite(
            secret.id,
            alice.id,
            Permissions::VIEW_CHANNEL,
            Permissions::NONE,
        )
        .await
        .unwrap();
    f.post(secret.id, &alice, 2).await;

    let bobs = f.read_states(&bob).await;
    assert_eq!(bobs.keys().collect::<Vec<_>>(), vec![&open.id.to_string()]);
    let (status, _) = f.get(&format!("/channels/{}/read", secret.id), &bob).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let alices = f.read_states(&alice).await;
    assert_eq!(alices.len(), 2);
    assert_eq!(alices[&secret.id.to_string()]["unread"], 2);
}

#[tokio::test]
async fn an_account_with_no_markers_and_no_channels_gets_an_empty_list() {
    let f = setup().await;
    let alice = f.account("alice").await;
    assert!(f.read_states(&alice).await.is_empty());

    let channel = f.store.create_channel("general", "text").await.unwrap();
    let rows = f.read_states(&alice).await;
    assert_eq!(rows.len(), 1);
    let row = &rows[&channel.id.to_string()];
    assert_eq!(
        (row["last_read_seq"].as_i64(), row["unread"].as_i64()),
        (Some(0), Some(0))
    );
}

#[tokio::test]
async fn includes_the_callers_dms_hidden_or_not_and_nobody_elses() {
    let f = setup().await;
    let alice = f.account("alice").await;
    let bob = f.account("bob").await;
    let carol = f.account("carol").await;
    let shown = f.store.open_dm(alice.id, bob.id).await.unwrap();
    let hidden = f.store.open_dm(alice.id, carol.id).await.unwrap();
    let other = f.store.open_dm(bob.id, carol.id).await.unwrap();
    f.post(shown.id, &bob, 2).await;
    f.store
        .hide_dm_conversation(alice.id, carol.id)
        .await
        .unwrap();

    let rows = f.read_states(&alice).await;
    assert!(rows.contains_key(&shown.id.to_string()));
    assert!(rows.contains_key(&hidden.id.to_string()));
    assert!(!rows.contains_key(&other.id.to_string()));
    assert_eq!(rows[&shown.id.to_string()]["unread"], 2);
    let (status, single) = f
        .get(&format!("/channels/{}/read", hidden.id), &alice)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(single["unread"], rows[&hidden.id.to_string()]["unread"]);
}

#[tokio::test]
async fn requires_a_signed_in_caller() {
    let f = setup().await;
    let request = Request::builder()
        .uri("/read-states")
        .body(Body::empty())
        .unwrap();
    let response = f.app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}
