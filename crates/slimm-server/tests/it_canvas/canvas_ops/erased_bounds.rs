// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What an erased or superseded canvas write leaves behind: the feed hides it, and
//! the tables that keep it stay bounded.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpRequest, MAX_OBJECTS_PER_CHANNEL, PlaceRequest, Store};
use sqlx::SqlitePool;

use crate::canvas_ops::fixtures::{
    app, edit_op, general, get_ops, id, member, new_store_and_pool, note, post_object, register,
    remove, submit_op,
};
use crate::support::canvas::{DAY_MS, age_canvas_history};

fn edit_props(ops: &Value) -> Vec<Value> {
    ops["ops"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|op| op["kind"] == "edit")
        .map(|op| op["props"].clone())
        .collect()
}

async fn place(store: &Store, channel: ChannelId, author: UserId) -> CanvasObjectId {
    let object = CanvasObjectId::generate();
    let request = PlaceRequest {
        kind: "stroke",
        bounds: (0.0, 0.0, 10.0, 10.0),
        props: "{}",
        attachment: None,
    };
    store
        .place_canvas_object(channel, author, object, request)
        .await
        .expect("placed");
    object
}

async fn erase(store: &Store, channel: ChannelId, actor: UserId, object: CanvasObjectId) {
    let request = CanvasOpRequest::Remove(vec![object]);
    store
        .submit_canvas_op(channel, actor, CanvasOpId::generate(), true, request)
        .await
        .expect("erased");
}

async fn count(pool: &SqlitePool, sql: &str) -> i64 {
    sqlx::query_scalar(sqlx::AssertSqlSafe(sql.to_owned()))
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn the_feed_withholds_the_text_of_an_erased_note_from_everyone_but_a_moderator() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (root, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (carol, _) = member(&store, "carol").await;
    let (_, placed) = post_object(&app, channel, &bob, note(&id(), "first")).await;
    let object = placed["id"].as_str().unwrap().to_owned();
    let secret = json!({ "text": "private words", "color": "annotation" });
    let (status, _) = submit_op(&app, channel, &bob, edit_op(&id(), &object, secret.clone())).await;
    assert_eq!(status, StatusCode::CREATED);

    let (_, ops) = get_ops(&app, channel, &carol, "after_seq=0").await;
    assert_eq!(
        edit_props(&ops),
        vec![secret.clone()],
        "live text is served"
    );

    let (status, _) = submit_op(&app, channel, &bob, remove(&id(), &[&object])).await;
    assert_eq!(status, StatusCode::CREATED);

    let (_, ops) = get_ops(&app, channel, &carol, "after_seq=0").await;
    assert_eq!(edit_props(&ops), vec![json!({})]);
    assert!(!ops.to_string().contains("private words"), "{ops}");
    let (_, ops) = get_ops(&app, channel, &root, "after_seq=0").await;
    assert_eq!(
        edit_props(&ops),
        vec![secret],
        "a moderator keeps the trail"
    );
}

#[tokio::test]
async fn the_feed_serves_a_live_note_s_current_text_for_every_earlier_edit() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (carol, _) = member(&store, "carol").await;
    let (_, placed) = post_object(&app, channel, &bob, note(&id(), "first")).await;
    let object = placed["id"].as_str().unwrap().to_owned();
    for text in ["phone 555 0100", "redacted"] {
        let props = json!({ "text": text, "color": "annotation" });
        submit_op(&app, channel, &bob, edit_op(&id(), &object, props)).await;
    }

    let (_, ops) = get_ops(&app, channel, &carol, "after_seq=0").await;
    let current = json!({ "text": "redacted", "color": "annotation" });
    assert_eq!(edit_props(&ops), vec![current.clone(), current]);
    assert!(!ops.to_string().contains("phone 555 0100"), "{ops}");
}

#[tokio::test]
async fn a_place_and_erase_loop_stays_under_the_erased_ceiling() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, author) = register(&store, "root").await;
    let channel = general(&store).await;
    let ceiling = MAX_OBJECTS_PER_CHANNEL * 2;
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
         INSERT INTO canvas_objects
             (id, channel_id, channel_key, kind, z_index, x, y, w, h,
              author_id, seq, created_at, deleted_at)
         SELECT randomblob(16), ?, 0, 'stroke', i, 0, 0, 1, 1, ?, i - 100000, 0, 1 FROM n",
    )
    .bind(ceiling - 5)
    .bind(channel)
    .bind(author)
    .execute(&pool)
    .await
    .unwrap();
    crate::support::canvas::backfill_props(&pool).await;

    for _ in 0..50 {
        let object = place(&store, channel, author).await;
        erase(&store, channel, author, object).await;
    }

    let rows = count(&pool, "SELECT COUNT(*) FROM canvas_objects").await;
    assert!(rows <= ceiling, "{rows} rows kept");
    let props = count(&pool, "SELECT COUNT(*) FROM canvas_object_props").await;
    assert_eq!(props, rows, "an evicted object leaves no props behind");
    let oldest = count(
        &pool,
        "SELECT COUNT(*) FROM canvas_objects WHERE seq = -99999",
    )
    .await;
    assert_eq!(oldest, 0, "the oldest erased objects go first");
}

async fn seed_erased(pool: &SqlitePool, channel: ChannelId, author: UserId, n: i64, first: i64) {
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
         INSERT INTO canvas_objects
             (id, channel_id, channel_key, kind, z_index, x, y, w, h,
              author_id, seq, created_at, deleted_at)
         SELECT randomblob(16), ?, 0, 'stroke', i, 0, 0, 1, 1, ?, i + ?, 0, 1 FROM n",
    )
    .bind(n)
    .bind(channel)
    .bind(author)
    .bind(first)
    .execute(pool)
    .await
    .unwrap();
    crate::support::canvas::backfill_props(pool).await;
}

#[tokio::test]
async fn eviction_never_takes_an_object_a_moderator_erased() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, root) = register(&store, "root").await;
    let (_, bob) = member(&store, "bob").await;
    let channel = general(&store).await;
    let evidence = place(&store, channel, bob).await;
    erase(&store, channel, root, evidence).await;
    seed_erased(&pool, channel, bob, MAX_OBJECTS_PER_CHANNEL * 2, 1_000).await;

    for _ in 0..5 {
        place(&store, channel, bob).await;
    }

    let kept = count(&pool, "SELECT COUNT(*) FROM canvas_audit_log").await;
    assert_eq!(kept, 1, "the moderator's audit row survives");
    let still = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM canvas_objects WHERE id = ?")
        .bind(evidence)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(still, 1, "the object it names survives");
}

#[tokio::test]
async fn a_placement_evicts_a_bounded_slice_of_an_old_backlog_and_the_sweep_drains_the_rest() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, author) = register(&store, "root").await;
    let channel = general(&store).await;
    let ceiling = MAX_OBJECTS_PER_CHANNEL * 2;
    seed_erased(&pool, channel, author, ceiling + 1_000, -100_000).await;

    place(&store, channel, author).await;

    let after_place = count(&pool, "SELECT COUNT(*) FROM canvas_objects").await;
    assert!(
        after_place > ceiling,
        "one placement drained the backlog: {after_place}"
    );
    store.sweep_canvas_ops().await.unwrap();
    let after_sweep = count(
        &pool,
        "SELECT COUNT(*) FROM canvas_objects WHERE deleted_at IS NOT NULL",
    )
    .await;
    assert!(after_sweep <= ceiling, "{after_sweep} left after the sweep");
}

#[tokio::test]
async fn the_erased_count_and_eviction_use_the_erased_index() {
    let (_store, pool, _guard) = new_store_and_pool().await;
    let rows: Vec<(i64, i64, i64, String)> = sqlx::query_as(
        "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM canvas_objects
         WHERE channel_id = x'00' AND deleted_at IS NOT NULL",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    let detail = rows
        .iter()
        .map(|r| r.3.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    assert!(detail.contains("canvas_objects_channel_erased"), "{detail}");
}

#[tokio::test]
async fn edits_past_the_window_compact_to_the_latest_per_object() {
    let (store, pool, _guard) = new_store_and_pool().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let mut notes = Vec::new();
    for name in ["one", "two"] {
        let (_, placed) = post_object(&app, channel, &bob, note(&id(), name)).await;
        notes.push(placed["id"].as_str().unwrap().to_owned());
    }
    for round in 0..3 {
        for object in &notes {
            let props = json!({ "text": format!("v{round}"), "color": "annotation" });
            submit_op(&app, channel, &bob, edit_op(&id(), object, props)).await;
        }
    }
    age_canvas_history(&pool, 31).await;

    let swept = store.sweep_canvas_ops().await.unwrap();

    assert_eq!(swept.edits, 4);
    let left = count(&pool, "SELECT COUNT(*) FROM canvas_ops WHERE kind = 'edit'").await;
    assert_eq!(left, 2, "the latest edit of each note stays");
    let (_, ops) = get_ops(&app, channel, &bob, "after_seq=1").await;
    assert_eq!(
        ops["reset"], true,
        "a cursor behind the gap is told to resync"
    );
}

#[tokio::test]
async fn a_member_erasing_their_own_ink_writes_no_audit_row_and_a_moderator_does() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, root) = register(&store, "root").await;
    let (_, bob) = member(&store, "bob").await;
    let channel = general(&store).await;
    let own = place(&store, channel, bob).await;
    erase(&store, channel, bob, own).await;
    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM canvas_audit_log").await,
        0
    );

    let theirs = place(&store, channel, bob).await;
    erase(&store, channel, root, theirs).await;
    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM canvas_audit_log").await,
        1
    );
}

#[tokio::test]
async fn old_audit_rows_are_swept_and_young_ones_kept() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, root) = register(&store, "root").await;
    let (_, bob) = member(&store, "bob").await;
    let channel = general(&store).await;
    for _ in 0..2 {
        let object = place(&store, channel, bob).await;
        erase(&store, channel, root, object).await;
    }
    sqlx::query("UPDATE canvas_audit_log SET created_at = created_at - ? WHERE id = (SELECT MIN(id) FROM canvas_audit_log)")
        .bind(400 * DAY_MS)
        .execute(&pool)
        .await
        .unwrap();

    let swept = store.sweep_canvas_ops().await.unwrap();

    assert_eq!(swept.audit, 1);
    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM canvas_audit_log").await,
        1
    );
}

async fn erased_ago(store: &Store, pool: &SqlitePool, channel: ChannelId, by: UserId, days: i64) {
    let object = place(store, channel, by).await;
    erase(store, channel, by, object).await;
    sqlx::query("UPDATE canvas_objects SET deleted_at = deleted_at - ? WHERE id = ?")
        .bind(days * DAY_MS)
        .bind(object)
        .execute(pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_channels_own_retention_decides_when_its_erased_objects_go() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, root) = register(&store, "root").await;
    let channel = general(&store).await;
    store
        .set_channel_retention_days(channel, Some(7))
        .await
        .unwrap();
    erased_ago(&store, &pool, channel, root, 10).await;
    store.sweep_canvas_ops().await.unwrap();
    let after_override = count(&pool, "SELECT COUNT(*) FROM canvas_objects").await;
    assert_eq!(
        after_override, 0,
        "the channel window applies with the space off"
    );

    store.set_message_retention_days(7).await.unwrap();
    store
        .set_channel_retention_days(channel, Some(0))
        .await
        .unwrap();
    erased_ago(&store, &pool, channel, root, 10).await;
    store.sweep_canvas_ops().await.unwrap();
    let after_keep = count(&pool, "SELECT COUNT(*) FROM canvas_objects").await;
    assert_eq!(
        after_keep, 1,
        "a channel kept forever is not purged on the space window"
    );
}

#[tokio::test]
async fn a_sweep_reclaims_every_eligible_row_past_ineligible_ones() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, root) = register(&store, "root").await;
    let channel = general(&store).await;
    for _ in 0..3 {
        let object = place(&store, channel, root).await;
        erase(&store, channel, root, object).await;
    }
    for _ in 0..520 {
        let object = place(&store, channel, root).await;
        let removed = CanvasOpId::generate();
        let request = CanvasOpRequest::Remove(vec![object]);
        store
            .submit_canvas_op(channel, root, removed, true, request)
            .await
            .unwrap();
        let undo = CanvasOpRequest::Restore { target_op: removed };
        store
            .submit_canvas_op(channel, root, CanvasOpId::generate(), true, undo)
            .await
            .unwrap();
    }
    age_canvas_history(&pool, 31).await;

    let swept = store.sweep_canvas_ops().await.unwrap();

    assert_eq!((swept.restores, swept.removes), (520, 520));
    let left = count(
        &pool,
        "SELECT COUNT(*) FROM canvas_ops WHERE kind = 'remove'",
    )
    .await;
    assert_eq!(left, 3, "the still-erased removes stay");
}
