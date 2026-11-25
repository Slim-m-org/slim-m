// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Exporting a board: the transaction, its retries, its bounds, who may, and who sees the copy.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::{CanvasEvent, Event};
use slimm_server::ids::{CanvasObjectId, ChannelId};
use slimm_server::store::MAX_EXPORT_OBJECTS;
use tokio::sync::broadcast::Receiver;

use crate::canvas_export::Rig;
use crate::support::app::{json_body, request_bare, request_bearer};
use crate::support::canvas::BoardChannels;

fn drain(events: &mut Receiver<Event>) -> Vec<Event> {
    std::iter::from_fn(|| events.try_recv().ok()).collect()
}

fn with_clear(mut body: Value) -> Value {
    body["clear_source"] = json!(true);
    body
}

pub(crate) async fn live(rig: &Rig, channel: ChannelId) -> i64 {
    rig.scalar(
        "SELECT COUNT(*) FROM canvas_objects WHERE channel_id = ? AND deleted_at IS NULL",
        channel,
    )
    .await
}

async fn exports_of(rig: &Rig, channel: ChannelId) -> i64 {
    rig.scalar(
        "SELECT COUNT(*) FROM canvas_exports WHERE channel_id = ?",
        channel,
    )
    .await
}

async fn channels_named(rig: &Rig, id: ChannelId) -> i64 {
    rig.scalar("SELECT COUNT(*) FROM channels WHERE id = ?", id)
        .await
}

/// Fills a board past anything a request could place in one go, straight through SQL.
async fn seed_raw(rig: &Rig, channel: ChannelId, count: i64) {
    let key = i64::from(channel.0.as_bytes()[15]);
    let mut tx = rig.pool.begin().await.unwrap();
    for n in 0..count {
        let id = CanvasObjectId::generate();
        sqlx::query(
            "INSERT INTO canvas_objects (id, channel_id, channel_key, kind, z_index, x, y, w, h, author_id, seq, created_at) \
             VALUES (?, ?, ?, 'note', ?, 0, 0, 10, 10, ?, ?, 1)",
        )
        .bind(id)
        .bind(channel)
        .bind(key)
        .bind(n + 1)
        .bind(rig.admin)
        .bind(n + 1)
        .execute(&mut *tx)
        .await
        .unwrap();
        sqlx::query("INSERT INTO canvas_object_props (object_id, props) VALUES (?, '{}')")
            .bind(id)
            .execute(&mut *tx)
            .await
            .unwrap();
    }
    sqlx::query(
        "UPDATE channel_seq_counters SET next_seq = ? WHERE channel_id = ? AND stream = 'canvas'",
    )
    .bind(count + 1)
    .bind(channel)
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
}

pub(crate) async fn get(rig: &Rig, uri: &str, token: Option<&str>) -> Value {
    let request = match token {
        Some(token) => request_bearer("GET", uri, token),
        None => request_bare("GET", uri, None),
    };
    json_body(
        tower::ServiceExt::oneshot(rig.app.clone(), request)
            .await
            .unwrap(),
    )
    .await
}

#[tokio::test]
async fn the_copy_and_the_clear_commit_together_and_announce_in_order() {
    let rig = Rig::new().await;
    let mut events = rig.hub.subscribe();
    let pinned = rig.place("note", json!({ "text": "pinned" })).await;
    rig.place("note", json!({ "text": "free" })).await;
    sqlx::query("INSERT INTO canvas_object_locks (object_id, channel_id, locked_by, locked_at) VALUES (?, ?, ?, 1)")
        .bind(pinned)
        .bind(rig.source)
        .bind(rig.admin)
        .execute(&rig.pool)
        .await
        .unwrap();

    let id = ChannelId::generate();
    let (status, body) = rig.export(with_clear(Rig::body(id, "copy"))).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        (
            body["copied"].as_i64(),
            body["cleared"].as_i64(),
            body["spared"].as_i64()
        ),
        (Some(2), Some(1), Some(1))
    );
    assert_eq!(live(&rig, rig.source).await, 1, "the locked note stays");
    assert_eq!(live(&rig, id).await, 2);
    let seen = drain(&mut events);
    let created = seen
        .iter()
        .position(|e| matches!(e, Event::ChannelCreated(c, _) if c.id == id));
    let cleared = seen.iter().position(|e| {
        matches!(e, Event::Canvas(CanvasEvent::Cleared { channel_id, spared_count: 1, .. }) if *channel_id == rig.source)
    });
    assert!(created.is_some() && created < cleared && cleared.is_some());
}

#[tokio::test]
async fn what_is_drawn_after_the_export_survives_and_is_not_in_the_copy() {
    let rig = Rig::new().await;
    rig.place("note", json!({ "text": "before" })).await;
    let id = ChannelId::generate();
    rig.export(with_clear(Rig::body(id, "copy"))).await;
    rig.place("note", json!({ "text": "after" })).await;

    assert_eq!(live(&rig, rig.source).await, 1);
    assert_eq!(live(&rig, id).await, 1);
}

#[tokio::test]
async fn a_failure_after_the_copy_leaves_no_channel_no_record_and_the_source_whole() {
    let rig = Rig::new().await;
    rig.place("note", json!({ "text": "a" })).await;
    rig.place("note", json!({ "text": "b" })).await;
    rig.exec("CREATE TRIGGER refuse_export BEFORE INSERT ON canvas_exports BEGIN SELECT RAISE(ABORT, 'injected'); END")
        .await;
    let before = rig.rows(rig.source).await;

    let id = ChannelId::generate();
    let (status, _) = rig.export(with_clear(Rig::body(id, "copy"))).await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        (channels_named(&rig, id).await, exports_of(&rig, id).await),
        (0, 0)
    );
    assert_eq!(live(&rig, id).await, 0);
    assert_eq!(rig.rows(rig.source).await, before, "nothing was cleared");
    let clears = rig
        .scalar(
            "SELECT COUNT(*) FROM canvas_ops WHERE channel_id = ? AND kind = 'clear'",
            rig.source,
        )
        .await;
    assert_eq!(clears, 0);
}

#[tokio::test]
async fn a_retry_replays_the_outcome_with_no_second_frame_and_no_second_clear() {
    let rig = Rig::new().await;
    let mut events = rig.hub.subscribe();
    rig.place("note", json!({ "text": "a" })).await;
    let id = ChannelId::generate();
    let (_, first) = rig.export(with_clear(Rig::body(id, "copy"))).await;
    rig.place("note", json!({ "text": "drawn since" })).await;
    drain(&mut events);

    let (status, again) = rig.export(with_clear(Rig::body(id, "copy"))).await;

    assert_eq!(status, StatusCode::OK, "{again}");
    assert_eq!(again, first);
    assert_eq!(
        live(&rig, rig.source).await,
        1,
        "the retry cleared nothing more"
    );
    let frames = drain(&mut events);
    assert!(
        frames.iter().all(|e| !matches!(
            e,
            Event::ChannelCreated(..) | Event::Canvas(CanvasEvent::Cleared { .. })
        )),
        "{} frames after the retry",
        frames.len()
    );
}

#[tokio::test]
async fn the_same_id_for_another_source_or_another_clear_choice_is_a_conflict() {
    let rig = Rig::new().await;
    let other = rig
        .store
        .create_voice_with_canvas("other")
        .await
        .unwrap()
        .id;
    rig.place("note", json!({ "text": "a" })).await;
    let id = ChannelId::generate();
    rig.export(Rig::body(id, "copy")).await;

    let (other_source, _) = rig
        .export_from(&rig.token, other, Rig::body(id, "copy"))
        .await;
    let (other_choice, _) = rig.export(with_clear(Rig::body(id, "copy"))).await;

    assert_eq!(
        (other_source, other_choice),
        (StatusCode::CONFLICT, StatusCode::CONFLICT)
    );
    assert_eq!(
        live(&rig, rig.source).await,
        1,
        "a conflicting retry cleared nothing"
    );
}

#[tokio::test]
async fn the_id_of_a_channel_no_export_made_is_a_conflict_and_the_source_is_untouched() {
    let rig = Rig::new().await;
    rig.place("note", json!({ "text": "a" })).await;
    let taken = rig
        .store
        .create_canvas_channel("plain", false)
        .await
        .unwrap()
        .id;

    let (status, _) = rig.export(with_clear(Rig::body(taken, "copy"))).await;

    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(live(&rig, rig.source).await, 1);
    assert_eq!(
        (live(&rig, taken).await, exports_of(&rig, taken).await),
        (0, 0)
    );
}

#[tokio::test]
async fn a_board_over_the_ceiling_is_too_large_and_nothing_is_written() {
    let rig = Rig::new().await;
    seed_raw(&rig, rig.source, MAX_EXPORT_OBJECTS + 1).await;

    let id = ChannelId::generate();
    let (status, body) = rig.export(with_clear(Rig::body(id, "copy"))).await;

    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["code"], "canvas_export_too_large");
    assert_eq!(channels_named(&rig, id).await, 0);
    assert_eq!(live(&rig, rig.source).await, MAX_EXPORT_OBJECTS + 1);
}

#[tokio::test]
async fn a_cap_lowered_under_the_source_refuses_with_nothing_written() {
    let rig = Rig::new().await;
    seed_raw(&rig, rig.source, 101).await;
    rig.store.set_canvas_object_cap(100).await.unwrap();

    let id = ChannelId::generate();
    let (status, body) = rig.export(with_clear(Rig::body(id, "copy"))).await;

    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"], "this canvas is full");
    assert_eq!(channels_named(&rig, id).await, 0);
    assert_eq!(live(&rig, rig.source).await, 101);
}

#[tokio::test]
async fn a_second_export_of_a_busy_source_is_refused_while_another_source_goes_on() {
    let rig = Rig::new().await;
    let other = rig
        .store
        .create_voice_with_canvas("other")
        .await
        .unwrap()
        .id;
    rig.place("note", json!({ "text": "a" })).await;
    let hold = slimm_server::http::hold_export_slot(rig.source).unwrap();

    let (status, body) = rig.export(Rig::body(ChannelId::generate(), "second")).await;
    let (elsewhere, _) = rig
        .export_from(
            &rig.token,
            other,
            Rig::body(ChannelId::generate(), "elsewhere"),
        )
        .await;
    drop(hold);
    let (again, _) = rig.export(Rig::body(ChannelId::generate(), "third")).await;

    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["code"], "canvas_export_busy");
    assert_eq!((elsewhere, again), (StatusCode::OK, StatusCode::OK));
    assert_eq!(
        rig.scalar(
            "SELECT COUNT(*) FROM canvas_exports WHERE source_channel_id = ?",
            rig.source
        )
        .await,
        1
    );
}

#[tokio::test]
async fn exports_have_their_own_budget_and_leave_the_boards_alone() {
    let rig = Rig::new().await;
    let mut statuses = Vec::new();
    for n in 0..6 {
        let body = Rig::body(ChannelId::generate(), &format!("copy {n}"));
        statuses.push(rig.export(body).await.0);
    }
    let ok = statuses.iter().filter(|s| **s == StatusCode::OK).count();
    assert_eq!(
        (ok, statuses[5]),
        (5, StatusCode::TOO_MANY_REQUESTS),
        "{statuses:?}"
    );

    let stroke = crate::canvas_ops::fixtures::stroke(&crate::canvas_ops::fixtures::id());
    let (placed, _) =
        crate::canvas_ops::fixtures::post_object(&rig.app, rig.source, &rig.token, stroke).await;
    assert_eq!(
        placed,
        StatusCode::CREATED,
        "drawing is not charged to the export budget"
    );
}
