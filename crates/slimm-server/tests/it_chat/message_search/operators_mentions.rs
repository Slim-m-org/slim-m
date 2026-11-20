// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `mentions:` keeps only a direct `@username` outside code. Every message here
//! goes through the real send and edit routes, so the mention rows are the
//! ones a deployment writes, `@everyone` and role pings included.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use sqlx::SqlitePool;
use tower::ServiceExt;

use crate::message_search::fixtures::*;

struct World {
    store: Store,
    pool: SqlitePool,
    app: Router,
    alice: String,
    bob: String,
    lobby: String,
    vault: ChannelId,
    _guard: crate::support::TestDbGuard,
}

/// Alice searches; Bob writes, and may ping everyone and a mentionable role Alice holds.
async fn world() -> World {
    let (store, pool, guard) = new_store_with_pool().await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MENTION_EVERYONE),
            true,
        )
        .await
        .unwrap();
    let lobby = store.create_channel("lobby", "text").await.unwrap().id;
    let vault = store.create_channel("vault", "text").await.unwrap().id;
    store
        .set_role_overwrite(
            vault,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    World {
        app: app(store.clone()),
        store,
        pool,
        alice,
        bob,
        lobby: lobby.to_string(),
        vault,
        _guard: guard,
    }
}

impl World {
    async fn say(&self, content: &str) -> String {
        let sent = send(&self.app, &self.lobby, &self.bob, content).await;
        sent["id"].as_str().unwrap().to_owned()
    }

    async fn found(&self, uri: &str) -> Vec<String> {
        let response = self
            .app
            .clone()
            .oneshot(request("GET", uri, Some(&self.alice), None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "{uri}");
        let body: Value = json_body(response).await;
        let mut out: Vec<String> = body
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["content"].as_str().unwrap().to_owned())
            .collect();
        out.sort();
        out
    }
}

#[tokio::test]
async fn only_a_direct_mention_outside_code_counts() {
    let w = world().await;
    for content in [
        "@alice look at this",
        "@everyone standup in 5, ask @alicebob",
        "@everyone mail bob@alice.dev",
        "@everyone run `@alice` in the shell",
        "@everyone\n```\n@alice\n```",
        "@here the build is green",
        "alice said hi",
    ] {
        w.say(content).await;
    }

    assert_eq!(
        w.found("/search/messages?mentions=alice").await,
        ["@alice look at this"]
    );
    assert_eq!(
        w.found("/search/messages?mentions=ALICE&q=look").await,
        ["@alice look at this"]
    );
    assert!(w.found("/search/messages?mentions=nobody").await.is_empty());
}

#[tokio::test]
async fn an_edit_that_drops_the_name_drops_the_mention() {
    let w = world().await;
    let id = w.say("@alice can you check").await;
    assert_eq!(w.found("/search/messages?mentions=alice").await.len(), 1);

    let response = w
        .app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}/messages/{id}", w.lobby),
            Some(&w.bob),
            Some(json!({ "content": "@everyone can you check" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    assert!(w.found("/search/messages?mentions=alice").await.is_empty());
}

#[tokio::test]
async fn a_mention_in_a_hidden_channel_never_answers() {
    let w = world().await;
    let bob = w
        .store
        .live_user_id_by_username("bob")
        .await
        .unwrap()
        .unwrap();
    let alice = w
        .store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    let id = MessageId::generate();
    let message = NewMessage::plain(w.vault, bob, id, "@alice the vault");
    w.store.send_message(message).await.unwrap();
    w.store
        .set_message_mentions(id, &[alice], None, &[alice])
        .await
        .unwrap();

    assert!(w.found("/search/messages?mentions=alice").await.is_empty());
    assert!(
        w.found("/search/messages?mentions=alice&in=vault")
            .await
            .is_empty()
    );
}

/// Rows from before migration 0203 have no answer yet; the startup sweep reads their text.
#[tokio::test]
async fn the_startup_sweep_decides_older_mentions_by_their_text() {
    let w = world().await;
    let direct = w.say("@alice older and direct").await;
    let broadcast = w.say("@everyone older, cc @alicebob").await;
    sqlx::query("UPDATE message_mentions SET direct = NULL")
        .execute(&w.pool)
        .await
        .unwrap();
    assert!(w.found("/search/messages?mentions=alice").await.is_empty());

    let decided = w.store.backfill_mention_directness().await.unwrap();

    assert_eq!(decided, 2, "{direct} and {broadcast} were undecided");
    assert_eq!(
        w.found("/search/messages?mentions=alice").await,
        ["@alice older and direct"]
    );
    assert_eq!(w.store.backfill_mention_directness().await.unwrap(), 0);
}

/// The sweep reads a batch's text, then decides it; an edit landing in between
/// already decided its own rows, and the stale text must not undo that.
#[tokio::test]
async fn the_sweep_never_undoes_an_edit_made_while_it_ran() {
    let w = world().await;
    let id = w.say("@everyone hi").await;
    sqlx::query("UPDATE message_mentions SET direct = NULL")
        .execute(&w.pool)
        .await
        .unwrap();
    let batch = w.store.undecided_mention_messages(200).await.unwrap();
    assert_eq!(batch.len(), 1);

    let response = w
        .app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}/messages/{id}", w.lobby),
            Some(&w.bob),
            Some(json!({ "content": "@everyone hi @alice" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let (message_id, stale_text) = &batch[0];
    assert_eq!(stale_text, "@everyone hi");
    w.store
        .decide_mention_directness(*message_id, &[])
        .await
        .unwrap();

    assert_eq!(
        w.found("/search/messages?mentions=alice").await,
        ["@everyone hi @alice"]
    );
}
