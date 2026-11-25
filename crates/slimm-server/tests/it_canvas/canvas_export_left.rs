// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Exporting with a clear never removes what the copy could not take, and a replay answers its stored outcome.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{CanvasOpId, ChannelId};

use crate::canvas_export::Rig;
use crate::canvas_ops::fixtures::{id, restore, submit_op};

fn with_clear(mut body: Value) -> Value {
    body["clear_source"] = json!(true);
    body
}

/// A board with a note, a tile of a module that is not installed, and an edge between the two.
async fn board_with_a_dead_tile(rig: &Rig) {
    let ghost = rig
        .place("module", json!({ "module_id": "ghost", "tile": "Board" }))
        .await;
    let note = rig.place("note", json!({ "text": "n" })).await;
    let props = json!({ "from": { "object_id": ghost.to_string() }, "to": { "object_id": note.to_string() } });
    rig.place("edge", props).await;
}

async fn kinds(rig: &Rig, channel: ChannelId) -> Vec<String> {
    rig.rows(channel)
        .await
        .into_iter()
        .map(|r| r.kind)
        .collect()
}

#[tokio::test]
async fn a_clearing_export_leaves_what_it_could_not_copy_on_the_source() {
    let rig = Rig::new().await;
    board_with_a_dead_tile(&rig).await;
    let id = ChannelId::generate();

    let (status, body) = rig.export(with_clear(Rig::body(id, "copy"))).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        [
            &body["copied"],
            &body["skipped"],
            &body["cleared"],
            &body["spared"],
            &body["left"]
        ],
        [&json!(1), &json!(2), &json!(1), &json!(0), &json!(2)]
    );
    assert_eq!(kinds(&rig, rig.source).await, ["module", "edge"]);
    assert_eq!(kinds(&rig, id).await, ["note"]);

    let (_, replay) = rig.export(with_clear(Rig::body(id, "copy"))).await;
    assert_eq!(replay["left"], 2, "a replay answers the same count");
}

#[tokio::test]
async fn an_export_without_a_clear_reports_nothing_left() {
    let rig = Rig::new().await;
    board_with_a_dead_tile(&rig).await;

    let (_, body) = rig.export(Rig::body(ChannelId::generate(), "copy")).await;

    assert_eq!((&body["skipped"], &body["left"]), (&json!(2), &json!(0)));
}

#[tokio::test]
async fn undoing_that_clear_brings_back_only_what_it_took() {
    let rig = Rig::new().await;
    board_with_a_dead_tile(&rig).await;
    rig.export(with_clear(Rig::body(ChannelId::generate(), "copy")))
        .await;
    let op: CanvasOpId =
        sqlx::query_scalar("SELECT id FROM canvas_ops WHERE channel_id = ? AND kind = 'clear'")
            .bind(rig.source)
            .fetch_one(&rig.pool)
            .await
            .unwrap();

    let undo = restore(&id(), &op.to_string());
    let (status, body) = submit_op(&rig.app, rig.source, &rig.token, undo).await;

    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(kinds(&rig, rig.source).await, ["module", "note", "edge"]);
}

#[tokio::test]
async fn a_replay_answers_the_stored_outcome_whatever_name_it_now_carries() {
    let rig = Rig::new().await;
    let first = ChannelId::generate();
    let (_, original) = rig.export(Rig::body(first, "copy")).await;

    let (status, replay) = rig.export(Rig::body(first, "a new name")).await;

    assert_eq!(status, StatusCode::OK, "{replay}");
    assert_eq!(replay, original);
}
