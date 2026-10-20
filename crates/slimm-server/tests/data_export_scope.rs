// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A thread is its own channel row, so the exports must judge it by the
//! channel and message it hangs from, and ids nested in JSON must be UUIDs.

use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::NewMessage;
use sqlx::SqlitePool;
use uuid::Uuid;

mod support;

use support::app::general_channel_id;
use support::exports::{Archive, World, account, world};

fn user(id: &str) -> UserId {
    UserId(id.parse().unwrap())
}

async fn channel_row(pool: &SqlitePool, kind: &str, room_owner: Option<&str>) -> Uuid {
    let id = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO channels (id, name, kind, room_owner_id, created_at) VALUES (?, ?, ?, ?, 1)",
    )
    .bind(id)
    .bind(format!("c-{id}"))
    .bind(kind)
    .bind(room_owner.map(|o| o.parse::<Uuid>().unwrap()))
    .execute(pool)
    .await
    .unwrap();
    counters(pool, id).await;
    id
}

async fn counters(pool: &SqlitePool, id: Uuid) {
    sqlx::query(
        "INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
         VALUES (?1, 'message', 1), (?1, 'canvas', 1)",
    )
    .bind(id)
    .execute(pool)
    .await
    .unwrap();
}

async fn post(store: &slimm_server::store::Store, channel: Uuid, author: &str, text: &str) -> Uuid {
    let id = MessageId::generate();
    let message = NewMessage::plain(ChannelId(channel), user(author), id, text);
    store.send_message(message).await.unwrap();
    id.0
}

async fn thread_under(pool: &SqlitePool, parent: Uuid) -> Uuid {
    let id = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO channels (id, name, kind, parent_message_id, created_at)
         VALUES (?, '', 'text', ?, 1)",
    )
    .bind(id)
    .bind(parent)
    .execute(pool)
    .await
    .unwrap();
    counters(pool, id).await;
    id
}

struct Fixture {
    w: World,
    pool: SqlitePool,
    alice: String,
    alice_id: String,
    _guard: support::TestDbGuard,
}

async fn fixture(prefix: &str) -> Fixture {
    let (store, pool, guard) = support::new_store_with_pool(prefix).await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    Fixture {
        w,
        pool,
        alice,
        alice_id,
        _guard: guard,
    }
}

impl Fixture {
    /// Posts a message, opens a thread under it and writes `secret` in the thread.
    async fn thread_with(&self, channel: Uuid, secret: &str) -> (Uuid, Uuid) {
        let store = &self.w.store;
        let parent = post(store, channel, &self.alice_id, "thread starter").await;
        let thread = thread_under(&self.pool, parent).await;
        post(store, thread, &self.alice_id, secret).await;
        (parent, thread)
    }

    async fn archives(&self) -> (Archive, Archive) {
        let space = self.w.archive(&self.alice, "space").await;
        let member = self.w.archive(&self.alice, "member").await;
        (space, member)
    }
}

#[tokio::test]
async fn a_live_thread_is_exported_with_its_parent() {
    let f = fixture("slimm-export-thread-live").await;
    let general: Uuid = general_channel_id(&f.w.store).await.parse().unwrap();
    let (parent, thread) = f.thread_with(general, "LIVE-THREAD-TEXT").await;

    let (space, member) = f.archives().await;

    assert!(space.contains("LIVE-THREAD-TEXT"));
    let channels = space.lines("channels.jsonl");
    let row = channels.iter().find(|c| c["id"] == thread.to_string());
    assert_eq!(row.unwrap()["thread_of_message_id"], parent.to_string());
    assert!(member.contains("LIVE-THREAD-TEXT"));
}

#[tokio::test]
async fn a_thread_under_a_direct_message_stays_out_of_the_space_export() {
    let f = fixture("slimm-export-thread-dm").await;
    let (_, bob_id) = account(&f.w.store, "bob").await;
    let (_, dm) =
        f.w.call("POST", &format!("/dms/{bob_id}"), &f.alice, None)
            .await;
    let dm: Uuid = dm["channel_id"].as_str().unwrap().parse().unwrap();
    f.thread_with(dm, "DM-THREAD-SECRET").await;

    let (space, member) = f.archives().await;

    assert!(!space.contains("DM-THREAD-SECRET"), "a DM thread leaked");
    let own = member.lines("messages.jsonl");
    let row = own.iter().find(|m| m["content"] == "DM-THREAD-SECRET");
    assert_eq!(row.unwrap()["channel_kind"], "dm");
    assert!(row.unwrap()["channel_name"].is_null());
}

#[tokio::test]
async fn a_thread_in_a_temporary_room_stays_out_of_the_space_export() {
    let f = fixture("slimm-export-thread-room").await;
    let room = channel_row(&f.pool, "text", Some(&f.alice_id)).await;
    f.thread_with(room, "ROOM-THREAD-SECRET").await;

    let (space, _) = f.archives().await;

    assert!(
        !space.contains("ROOM-THREAD-SECRET"),
        "a room thread leaked"
    );
}

#[tokio::test]
async fn a_thread_left_in_a_deleted_channel_is_in_no_export() {
    let f = fixture("slimm-export-thread-channel").await;
    let gone = channel_row(&f.pool, "text", None).await;
    f.thread_with(gone, "DELETED-CHANNEL-THREAD").await;
    sqlx::query("UPDATE channels SET deleted_at = 5 WHERE id = ?")
        .bind(gone)
        .execute(&f.pool)
        .await
        .unwrap();

    let (space, member) = f.archives().await;

    assert!(!space.contains("DELETED-CHANNEL-THREAD"));
    assert!(!member.contains("DELETED-CHANNEL-THREAD"));
}

#[tokio::test]
async fn a_thread_left_under_a_deleted_message_is_in_no_export() {
    let f = fixture("slimm-export-thread-parent").await;
    let general: Uuid = general_channel_id(&f.w.store).await.parse().unwrap();
    let (parent, _) = f.thread_with(general, "DELETED-PARENT-THREAD").await;
    sqlx::query("UPDATE messages SET deleted_at = 5 WHERE id = ?")
        .bind(parent)
        .execute(&f.pool)
        .await
        .unwrap();

    let (space, member) = f.archives().await;

    assert!(!space.contains("DELETED-PARENT-THREAD"));
    assert!(!member.contains("DELETED-PARENT-THREAD"));
}

#[tokio::test]
async fn polls_and_calls_in_a_deleted_channel_stay_out_of_a_member_export() {
    let f = fixture("slimm-export-deleted-sections").await;
    let gone = channel_row(&f.pool, "voice", None).await;
    sqlx::query(
        "INSERT INTO voice_call_events (channel_id, user_id, at, kind) VALUES (?, ?, 7, 'joined')",
    )
    .bind(gone)
    .bind(f.alice_id.parse::<Uuid>().unwrap())
    .execute(&f.pool)
    .await
    .unwrap();
    let live = f.w.archive(&f.alice, "member").await;
    assert_eq!(live.lines("call_events.jsonl").len(), 1);
    sqlx::query("UPDATE channels SET deleted_at = 5 WHERE id = ?")
        .bind(gone)
        .execute(&f.pool)
        .await
        .unwrap();
    sqlx::query("UPDATE data_exports SET created_at = 1")
        .execute(&f.pool)
        .await
        .unwrap();

    let after = f.w.archive(&f.alice, "member").await;

    assert!(after.lines("call_events.jsonl").is_empty());
}

#[tokio::test]
async fn a_member_export_leaves_out_the_text_of_a_message_they_forwarded() {
    let f = fixture("slimm-export-forward-text").await;
    let general: Uuid = general_channel_id(&f.w.store).await.parse().unwrap();
    let copy = post(&f.w.store, general, &f.alice_id, "my forward").await;
    sqlx::query(
        "INSERT INTO message_forwards (message_id, origin_message_id, origin_channel_id,
             origin_author_id, origin_created_at, origin_content)
         VALUES (?, ?, ?, NULL, 3, 'FORWARD-ORIGIN-TEXT')",
    )
    .bind(copy)
    .bind(Uuid::now_v7())
    .bind(general)
    .execute(&f.pool)
    .await
    .unwrap();

    let (space, member) = f.archives().await;

    assert!(!member.contains("FORWARD-ORIGIN-TEXT"));
    let rows = member.lines("messages.jsonl");
    let forwarded = &rows.iter().find(|m| m["content"] == "my forward").unwrap()["forwarded_from"];
    assert_eq!(forwarded["origin_created_at"], 3);
    let shared = space.lines(&format!("channels/{general}/messages.jsonl"));
    let origin = &shared.iter().find(|m| m["id"] == copy.to_string()).unwrap()["forwarded_from"];
    assert!(origin["origin_author_id"].is_null(), "{origin}");
}

#[tokio::test]
async fn ids_nested_in_a_row_are_hyphenated_uuids_that_match_the_top_level_ones() {
    let f = fixture("slimm-export-nested-ids").await;
    let (_, bob_id) = account(&f.w.store, "bob").await;
    let role =
        f.w.store
            .create_role("crew", Permissions::NONE, false)
            .await
            .unwrap();
    f.w.store.assign_role(user(&bob_id), role).await.unwrap();

    let space = f.w.archive(&f.alice, "space").await;

    let roles = space.lines("roles.jsonl");
    let members = space.lines("members.jsonl");
    let bob = members.iter().find(|m| m["id"] == bob_id.as_str()).unwrap();
    let listed = bob["role_ids"][0].as_str().unwrap();
    assert!(roles.iter().any(|r| r["id"] == listed), "{listed}");
}
