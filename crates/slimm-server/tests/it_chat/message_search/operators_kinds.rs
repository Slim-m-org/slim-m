// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `has:` kinds past `attachment`/`link`, `mentions:` and `pinned:`. Every
//! test plants the same content in a channel the searcher cannot view, so
//! each filter is also pinned to never reach past the caller's scope.

use axum::Router;
use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use sqlx::SqlitePool;
use tower::ServiceExt;

use crate::message_search::fixtures::*;

/// A searcher who sees `lobby` but not `vault`, and `bob`, who writes in both.
struct World {
    store: Store,
    pool: SqlitePool,
    app: Router,
    token: String,
    alice: UserId,
    bob: UserId,
    lobby: ChannelId,
    vault: ChannelId,
    _guard: crate::support::TestDbGuard,
}

async fn world() -> World {
    let (store, pool, guard) = new_store_with_pool().await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
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
    let token = register(&store, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    let bob = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap()
        .id;
    World {
        app: app(store.clone()),
        store,
        pool,
        token,
        alice,
        bob,
        lobby,
        vault,
        _guard: guard,
    }
}

impl World {
    async fn say(&self, channel: ChannelId, content: &str) -> MessageId {
        let id = MessageId::generate();
        let message = NewMessage::plain(channel, self.bob, id, content);
        self.store.send_message(message).await.unwrap();
        id
    }

    /// A message carrying one file of `content_type`, its bytes unique to `content`.
    async fn attach(&self, channel: ChannelId, content: &str, content_type: &str) -> MessageId {
        let sha = blake_ish(content, channel);
        self.store
            .store_attachment(&sha, 10, content_type, "f.bin", Some(self.bob))
            .await
            .unwrap();
        let id = MessageId::generate();
        let ids = [sha.to_vec()];
        let message = NewMessage {
            attachment_ids: &ids,
            ..NewMessage::plain(channel, self.bob, id, content)
        };
        self.store.send_message(message).await.unwrap();
        id
    }

    async fn exec(&self, sql: &'static str, id: MessageId) {
        sqlx::query(sql).bind(id).execute(&self.pool).await.unwrap();
    }

    /// The same content in both channels, so each query below shows the vault never answers.
    async fn plant_kinds(&self) {
        for channel in [self.lobby, self.vault] {
            self.say(channel, "kinds plain").await;
            self.attach(channel, "kinds image", "image/png").await;
            self.attach(channel, "kinds video", "video/mp4").await;
            self.attach(channel, "kinds file", "application/pdf").await;
            let voice = self.attach(channel, "kinds voice", "audio/ogg").await;
            self.exec(
                "UPDATE message_attachments SET voice_duration_ms = 1000, \
                 voice_waveform = zeroblob(64) WHERE message_id = ?",
                voice,
            )
            .await;
            self.say(channel, "kinds link https://example.com").await;
            let embed = self.say(channel, "kinds embed").await;
            self.exec(
                "INSERT INTO message_embeds (message_id, position, title) VALUES (?, 0, 't')",
                embed,
            )
            .await;
            let poll = self.say(channel, "kinds poll").await;
            sqlx::query(
                "INSERT INTO polls (message_id, channel_id, question, created_at) VALUES (?, ?, 'q', 0)",
            )
            .bind(poll)
            .bind(channel)
            .execute(&self.pool)
            .await
            .unwrap();
        }
    }

    async fn get(&self, uri: &str) -> (StatusCode, Value) {
        let response = self
            .app
            .clone()
            .oneshot(request("GET", uri, Some(&self.token), None))
            .await
            .unwrap();
        let status = response.status();
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
    }

    /// Every hit's content for `uri`, sorted, after asserting it answered 200.
    async fn contents(&self, uri: &str) -> Vec<String> {
        let (status, body) = self.get(uri).await;
        assert_eq!(status, StatusCode::OK, "{uri}: {body}");
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

/// Distinct 32 bytes per message, so no two planted files share one blob.
fn blake_ish(content: &str, channel: ChannelId) -> [u8; 32] {
    let mut sha = [0u8; 32];
    let seed = format!("{content}{channel}");
    for (i, byte) in seed.bytes().enumerate() {
        sha[i % 32] = sha[i % 32].wrapping_mul(31).wrapping_add(byte);
    }
    sha
}

#[tokio::test]
async fn each_has_kind_narrows_to_its_own_content_in_viewable_channels_only() {
    let w = world().await;
    w.plant_kinds().await;

    let cases: [(&str, &[&str]); 8] = [
        (
            "attachment",
            &["kinds file", "kinds image", "kinds video", "kinds voice"],
        ),
        ("image", &["kinds image"]),
        ("video", &["kinds video"]),
        ("voice", &["kinds voice"]),
        ("file", &["kinds file"]),
        ("link", &["kinds link https://example.com"]),
        ("embed", &["kinds embed"]),
        ("poll", &["kinds poll"]),
    ];
    for (kind, expected) in cases {
        assert_eq!(
            w.contents(&format!("/search/messages?has={kind}")).await,
            *expected,
            "has={kind}"
        );
        let in_lobby = format!("/channels/{}/messages/search?q=kinds&has={kind}", w.lobby);
        assert_eq!(w.contents(&in_lobby).await, *expected, "lobby has={kind}");
        let in_vault = format!("/search/messages?in=vault&has={kind}");
        assert!(
            w.contents(&in_vault).await.is_empty(),
            "in:vault has={kind}"
        );
    }
}

#[tokio::test]
async fn several_has_kinds_must_all_hold() {
    let w = world().await;
    w.plant_kinds().await;
    w.attach(w.lobby, "kinds image https://x.test", "image/gif")
        .await;

    let hits = w.contents("/search/messages?has=image,link").await;
    assert_eq!(hits, ["kinds image https://x.test"]);
}

#[tokio::test]
async fn an_unknown_has_kind_is_refused() {
    let w = world().await;
    let (status, _) = w.get("/search/messages?has=image,sticker").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// Only a direct `@alice` that pinged her counts: not an `@everyone` that reached
/// her, not her name without the `@`, and never a mention in a channel she cannot view.
#[tokio::test]
async fn mentions_finds_direct_mentions_of_that_person() {
    let w = world().await;
    let mentioned = "INSERT INTO message_mentions (user_id, message_id) VALUES (?, ?)";
    for (channel, content, pinged) in [
        (w.lobby, "@alice look at this", true),
        (w.lobby, "@everyone standup", true),
        (w.lobby, "alice said hi", false),
        (w.vault, "@alice the vault", true),
    ] {
        let id = w.say(channel, content).await;
        if pinged {
            sqlx::query(mentioned)
                .bind(w.alice)
                .bind(id)
                .execute(&w.pool)
                .await
                .unwrap();
        }
    }

    for uri in [
        "/search/messages?mentions=alice".to_owned(),
        "/search/messages?mentions=ALICE".to_owned(),
        format!("/channels/{}/messages/search?mentions=alice", w.lobby),
    ] {
        assert_eq!(w.contents(&uri).await, ["@alice look at this"], "{uri}");
    }
    assert!(
        w.contents("/search/messages?mentions=nobody")
            .await
            .is_empty()
    );
    assert!(
        w.contents("/search/messages?mentions=alice&in=vault")
            .await
            .is_empty()
    );
}

#[tokio::test]
async fn pinned_true_and_false_split_what_the_caller_can_view() {
    let w = world().await;
    let pinned = w.say(w.lobby, "pins the plan").await;
    w.say(w.lobby, "pins the chatter").await;
    let hidden = w.say(w.vault, "pins the secret").await;
    w.store.pin_message(w.lobby, pinned, w.bob).await.unwrap();
    w.store.pin_message(w.vault, hidden, w.bob).await.unwrap();

    assert_eq!(
        w.contents("/search/messages?pinned=true").await,
        ["pins the plan"]
    );
    assert_eq!(
        w.contents("/search/messages?q=pins&pinned=false").await,
        ["pins the chatter"]
    );
    let lobby = format!("/channels/{}/messages/search?pinned=true", w.lobby);
    assert_eq!(w.contents(&lobby).await, ["pins the plan"]);
    let vault = format!("/channels/{}/messages/search?pinned=true", w.vault);
    assert_eq!(w.get(&vault).await.0, StatusCode::FORBIDDEN);
    let (status, _) = w.get("/search/messages?pinned=maybe").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// Every new operator also counts as a reason to run with no `q`; together they AND.
#[tokio::test]
async fn the_new_operators_combine_with_from_and_dates() {
    let w = world().await;
    w.plant_kinds().await;
    let pinned_image = w.attach(w.lobby, "kinds pinned image", "image/png").await;
    w.store
        .pin_message(w.lobby, pinned_image, w.bob)
        .await
        .unwrap();

    let uri = "/search/messages?has=image&pinned=true&from=bob&after_date=2000-01-01";
    assert_eq!(w.contents(uri).await, ["kinds pinned image"]);
    assert!(
        w.contents("/search/messages?has=image&pinned=true&from=alice")
            .await
            .is_empty()
    );
}
