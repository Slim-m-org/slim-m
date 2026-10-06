// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The DM rail's activity ordering, and the query plan behind it.
//!
//! `list_dm_conversations` used to order on a correlated
//! `MAX(m.created_at)`, which cannot use `messages_channel_live` to
//! short-circuit: it scanned every live message in each conversation, per
//! conversation, on a table nothing sweeps, so the rail's cost grew with a
//! deployment's whole history (~7,700x at 200k rows, measured by the
//! 2026-08-11 review). The seek form (`ORDER BY seq DESC LIMIT 1`) answers
//! identically because `seq` and `created_at` are allocated in the same
//! transaction, and the plan test here is what keeps the seek from quietly
//! regressing to a scan - the ordering tests alone would stay green through
//! that, which is exactly how the old form shipped.

mod support;

use std::fs;
use std::path::Path;

use slimm_server::ids::UserId;
use slimm_server::store::{NewMessage, Store};
use sqlx::{Row, SqlitePool};

async fn new_store(name: &str) -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    let pool = slimm_server::db::connect(&config)
        .await
        .expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn register(store: &Store, name: &str) -> UserId {
    store
        .create_account(name, name, "not-a-real-hash")
        .await
        .expect("register")
        .id
}

async fn send(store: &Store, channel: slimm_server::ids::ChannelId, author: UserId, text: &str) {
    store
        .send_message(NewMessage::plain(
            channel,
            author,
            slimm_server::ids::MessageId::generate(),
            text,
        ))
        .await
        .expect("send");
}

/// Everything in a fixture lands within one millisecond, and `activity_at`
/// ties order arbitrarily - the first run of this suite proved it by flaking.
/// Timestamps are pinned by hand so the ordering under test is the only
/// thing that can decide.
async fn newest_in(pool: &SqlitePool, channel: slimm_server::ids::ChannelId) -> Vec<u8> {
    sqlx::query_scalar::<_, Vec<u8>>(
        "SELECT id FROM messages WHERE channel_id = ? ORDER BY seq DESC LIMIT 1",
    )
    .bind(channel.0.as_bytes().to_vec())
    .fetch_one(pool)
    .await
    .expect("newest id")
}

async fn pin_created_at(pool: &SqlitePool, table: &str, id: &[u8], at: i64) {
    let sql = format!("UPDATE {table} SET created_at = ? WHERE id = ?");
    sqlx::query(&sql)
        .bind(at)
        .bind(id)
        .execute(pool)
        .await
        .expect("pin created_at");
}

#[tokio::test]
async fn conversations_order_by_newest_live_message_and_fall_back_to_creation() {
    let (store, pool, _guard) = new_store("slimm-dm-activity").await;
    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let carol = register(&store, "carol").await;

    let with_bob = store.open_dm(alice, bob).await.expect("dm bob").id;
    let with_carol = store.open_dm(alice, carol).await.expect("dm carol").id;

    // Newest activity in the bob conversation puts it first.
    send(&store, with_carol, carol, "older").await;
    send(&store, with_bob, bob, "newer").await;
    pin_created_at(
        &pool,
        "messages",
        &newest_in(&pool, with_carol).await,
        1_000,
    )
    .await;
    pin_created_at(&pool, "messages", &newest_in(&pool, with_bob).await, 2_000).await;
    let order: Vec<_> = store
        .list_dm_conversations(alice)
        .await
        .expect("list")
        .into_iter()
        .map(|c| c.channel_id)
        .collect();
    assert_eq!(order, vec![with_bob, with_carol]);

    // A reply into the carol conversation flips the order.
    send(&store, with_carol, alice, "newest of all").await;
    pin_created_at(
        &pool,
        "messages",
        &newest_in(&pool, with_carol).await,
        3_000,
    )
    .await;
    let order: Vec<_> = store
        .list_dm_conversations(alice)
        .await
        .expect("list")
        .into_iter()
        .map(|c| c.channel_id)
        .collect();
    assert_eq!(order, vec![with_carol, with_bob]);
}

/// Bob's only message is dead, so his conversation falls back to channel
/// creation time and carol's live message wins. The old MAX form and the
/// seek form agree here only because both filter `deleted_at`; this is the
/// case that would catch a seek that forgot the liveness predicate.
#[tokio::test]
async fn a_deleted_newest_message_does_not_carry_the_ordering() {
    let (store, pool, _guard) = new_store("slimm-dm-activity-del").await;
    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let carol = register(&store, "carol").await;

    let with_bob = store.open_dm(alice, bob).await.expect("dm bob").id;
    let with_carol = store.open_dm(alice, carol).await.expect("dm carol").id;

    // The channels' own creation times are the fallback; pin them apart too.
    pin_created_at(&pool, "channels", with_bob.0.as_bytes().as_slice(), 100).await;
    pin_created_at(&pool, "channels", with_carol.0.as_bytes().as_slice(), 200).await;
    send(&store, with_carol, carol, "carol speaks").await;
    let id = slimm_server::ids::MessageId::generate();
    store
        .send_message(NewMessage::plain(with_bob, bob, id, "bob speaks last"))
        .await
        .expect("send");
    store.delete_message(id, bob).await.expect("delete");

    let order: Vec<_> = store
        .list_dm_conversations(alice)
        .await
        .expect("list")
        .into_iter()
        .map(|c| c.channel_id)
        .collect();
    assert_eq!(order, vec![with_carol, with_bob]);
    drop(pool);
}

fn read_source(relative: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
    fs::read_to_string(&path).unwrap_or_else(|_| panic!("read {relative}"))
}

/// The raw-string body containing [anchor]; the technique
/// `tests/canvas_ops/index_plan.rs` documents, duplicated here because
/// integration-test binaries cannot import each other's helpers.
fn extract_raw_containing(source: &str, anchor: &str) -> String {
    let pos = source
        .find(anchor)
        .unwrap_or_else(|| panic!("{anchor:?} no longer appears in the source"));
    let start = source[..pos]
        .rfind("r#\"")
        .unwrap_or_else(|| panic!("no opening quote before {anchor:?}"))
        + 3;
    let end = source[pos..]
        .find("\"#")
        .unwrap_or_else(|| panic!("no closing quote after {anchor:?}"))
        + pos;
    source[start..end].to_owned()
}

/// The plan alone cannot kill a revert to `MAX(created_at)`: both forms plan
/// as `SEARCH m USING INDEX messages_channel_live (channel_id=?)`, because
/// the `LIMIT 1` short-circuit happens in the bytecode, below what EXPLAIN
/// QUERY PLAN reports - proven by applying that exact mutation and watching
/// the plan test stay green. So the shape itself is asserted from source (the
/// `rate_limit_coverage.rs` technique), and the plan test below still guards
/// the half it genuinely can see: losing the index entirely.
#[tokio::test]
async fn the_activity_lookup_is_the_seek_form_not_the_aggregate() {
    let source = read_source("src/store/dms.rs");
    let sql = extract_raw_containing(&source, "activity_at!: i64");
    assert!(
        sql.contains("ORDER BY m.seq DESC LIMIT 1"),
        "the activity subquery must seek the newest row by seq; got:\n{sql}"
    );
    assert!(
        !sql.to_uppercase().contains("MAX("),
        "an aggregate here scans every live message in the channel; got:\n{sql}"
    );
}

#[tokio::test]
async fn the_activity_subquery_seeks_the_live_index_rather_than_scanning() {
    let (_store, pool, _guard) = new_store("slimm-dm-activity-plan").await;
    let source = read_source("src/store/dms.rs");
    let sql = extract_raw_containing(&source, "activity_at!: i64");

    let explain = format!("EXPLAIN QUERY PLAN {sql}");
    let zero = vec![0u8; 16];
    let rows = sqlx::query(&explain)
        .bind(&zero)
        .bind(&zero)
        .bind(&zero)
        .bind(&zero)
        .fetch_all(&pool)
        .await
        .expect("plan");
    let details: Vec<String> = rows.iter().map(|r| r.get::<String, _>("detail")).collect();
    let plan = details.join("\n");

    let touches_messages = details
        .iter()
        .find(|d| d.contains(" m ") || d.ends_with(" m") || d.contains(" m USING"))
        .unwrap_or_else(|| panic!("no messages access in plan:\n{plan}"));
    assert!(
        touches_messages.contains("USING") && touches_messages.contains("messages_channel_live"),
        "the activity lookup must seek messages_channel_live, got:\n{plan}"
    );
    assert!(
        !plan.contains("SCAN m"),
        "the activity lookup must never scan messages:\n{plan}"
    );
}
