// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Exporting a board: connectors, module tiles and stacking order on the copy.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{CanvasObjectId, ChannelId};

use crate::canvas_export::{Rig, props_of};

#[tokio::test]
async fn an_edge_is_attached_to_the_copies_with_its_sides_and_free_ends_kept() {
    let rig = Rig::new().await;
    let a = rig
        .place_in(
            rig.source,
            "note",
            (0.0, 0.0, 100.0, 50.0),
            json!({ "text": "a" }),
        )
        .await;
    let b = rig
        .place_in(
            rig.source,
            "note",
            (300.0, 0.0, 100.0, 50.0),
            json!({ "text": "b" }),
        )
        .await;
    let attached = json!({ "from": { "object_id": a.to_string(), "side": "right" },
                           "to": { "object_id": b.to_string(), "side": "left" }, "arrow": "end" });
    let half_free = json!({ "from": { "object_id": a.to_string(), "side": "auto" },
                            "to": { "x": 500.0, "y": 90.0 }, "label": "later" });
    rig.place_in(rig.source, "edge", (0.0, 0.0, 1.0, 1.0), attached)
        .await;
    rig.place_in(rig.source, "edge", (0.0, 0.0, 1.0, 1.0), half_free)
        .await;
    let before = rig.rows(rig.source).await;
    let id = ChannelId::generate();

    let (status, body) = rig.export(Rig::body(id, "copy")).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["copied"], 4);
    let after = rig.rows(id).await;
    let (copy_a, copy_b) = (after[0].id.to_string(), after[1].id.to_string());
    let props: Vec<Value> = after.iter().map(props_of).collect();
    assert_eq!(
        props[2]["from"],
        json!({ "object_id": copy_a, "side": "right" })
    );
    assert_eq!(
        props[2]["to"],
        json!({ "object_id": copy_b, "side": "left" })
    );
    assert_eq!(
        props[3]["from"],
        json!({ "object_id": copy_a, "side": "auto" })
    );
    assert_eq!(props[3]["to"], json!({ "x": 500.0, "y": 90.0 }));
    assert_eq!(props[3]["label"], "later");
    for (old, new) in before.iter().zip(&after) {
        assert_eq!(
            [old.x, old.y, old.w, old.h],
            [new.x, new.y, new.w, new.h],
            "the hull is the source's"
        );
    }
    let stray = rig
        .scalar(
            "SELECT COUNT(*) FROM canvas_edge_ends e \
             JOIN canvas_objects edge ON edge.id = e.edge_id \
             LEFT JOIN canvas_objects o ON o.id = e.object_id AND o.channel_id = edge.channel_id \
             WHERE edge.channel_id = ? AND o.id IS NULL",
            id,
        )
        .await;
    assert_eq!(
        stray, 0,
        "every end of a copied edge names an object in the new channel"
    );
    let copied_ends = rig
        .scalar(
            "SELECT COUNT(*) FROM canvas_edge_ends e JOIN canvas_objects o ON o.id = e.edge_id \
             WHERE o.channel_id = ?",
            id,
        )
        .await;
    assert_eq!(copied_ends, 3);
    let source_ends = rig
        .scalar(
            "SELECT COUNT(*) FROM canvas_edge_ends e JOIN canvas_objects o ON o.id = e.edge_id \
             WHERE o.channel_id = ?",
            rig.source,
        )
        .await;
    assert_eq!(source_ends, 3, "the source's end rows are unchanged");
}

#[tokio::test]
async fn an_edge_that_lost_an_end_is_left_behind_and_counted() {
    let rig = Rig::new().await;
    let a = rig.place("note", json!({ "text": "a" })).await;
    let b = rig.place("note", json!({ "text": "b" })).await;
    let props =
        json!({ "from": { "object_id": a.to_string() }, "to": { "object_id": b.to_string() } });
    rig.place("edge", props).await;
    sqlx::query("UPDATE canvas_objects SET deleted_at = 1 WHERE id = ?")
        .bind(b)
        .execute(&rig.pool)
        .await
        .unwrap();

    let id = ChannelId::generate();
    let (status, body) = rig.export(Rig::body(id, "copy")).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        (body["copied"].as_i64(), body["skipped"].as_i64()),
        (Some(1), Some(1))
    );
    let kinds: Vec<String> = rig.rows(id).await.into_iter().map(|r| r.kind).collect();
    assert_eq!(kinds, ["note"]);
}

#[tokio::test]
async fn a_module_tile_is_copied_only_while_its_module_is_installed() {
    let rig = Rig::new().await;
    let tile = |module: &str| json!({ "module_id": module, "tile": "Board" });
    rig.place("module", tile("ghost")).await;
    let kept = rig.place("module", tile("board")).await;
    rig.exec(
        "INSERT INTO installed_modules (id, name, version, artifact_sha256, enabled, installed_at) \
         VALUES ('board', 'Board', '0.1.0', 'x', 1, 0)",
    )
    .await;
    let kept_note = rig.place("note", json!({ "text": "n" })).await;
    let props = json!({ "from": { "object_id": kept.to_string() }, "to": { "object_id": kept_note.to_string() } });
    rig.place("edge", props).await;

    let id = ChannelId::generate();
    let (status, body) = rig.export(Rig::body(id, "copy")).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        (body["copied"].as_i64(), body["skipped"].as_i64()),
        (Some(3), Some(1))
    );
}

#[tokio::test]
async fn an_edge_attached_to_a_skipped_tile_is_skipped_with_it() {
    let rig = Rig::new().await;
    let ghost = rig
        .place("module", json!({ "module_id": "ghost", "tile": "Board" }))
        .await;
    let note = rig.place("note", json!({ "text": "n" })).await;
    let props = json!({ "from": { "object_id": ghost.to_string() }, "to": { "object_id": note.to_string() } });
    rig.place("edge", props).await;

    let id = ChannelId::generate();
    let (_, body) = rig.export(Rig::body(id, "copy")).await;

    assert_eq!(
        (body["copied"].as_i64(), body["skipped"].as_i64()),
        (Some(1), Some(2))
    );
}

#[tokio::test]
async fn stacking_order_survives_for_every_kind_an_edge_between_two_notes_stays_between() {
    let rig = Rig::new().await;
    let a = rig
        .place_in(
            rig.source,
            "note",
            (0.0, 0.0, 100.0, 50.0),
            json!({ "text": "a" }),
        )
        .await;
    let edge_props = |a: CanvasObjectId, b: CanvasObjectId| json!({ "from": { "object_id": a.to_string() }, "to": { "object_id": b.to_string() } });
    let b = rig
        .place_in(
            rig.source,
            "note",
            (300.0, 0.0, 100.0, 50.0),
            json!({ "text": "b" }),
        )
        .await;
    rig.place("edge", edge_props(a, b)).await;
    rig.place("stroke", json!({ "points": [0.0, 0.0] })).await;
    // Raising the first note puts it above everything drawn after it.
    rig.exec("UPDATE canvas_objects SET z_index = 1000 WHERE id = (SELECT id FROM canvas_objects ORDER BY seq LIMIT 1)")
        .await;
    let before: Vec<String> = rig
        .rows(rig.source)
        .await
        .into_iter()
        .map(|r| r.kind)
        .collect();

    let id = ChannelId::generate();
    rig.export(Rig::body(id, "copy")).await;

    let after: Vec<String> = rig.rows(id).await.into_iter().map(|r| r.kind).collect();
    assert_eq!(after, before);
    assert_eq!(after, ["note", "edge", "stroke", "note"]);
}
