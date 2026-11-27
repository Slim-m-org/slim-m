// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas place batch with a connection in it, and the 403 that names a missing permission.

use serde_json::json;
use uuid::Uuid;

use crate::response_contract::world::{Contract, Payload};

/// Places a stroke, two notes and the edge between them in one batch, then refuses a member's remove.
pub(super) async fn canvas_batch_calls(
    c: &mut Contract,
    root: &str,
    member: &str,
    board: &str,
    first_object_id: &str,
) {
    let (left, right) = (Uuid::now_v7().to_string(), Uuid::now_v7().to_string());
    c.json(
        "placeCanvasObjects",
        "POST",
        &format!("/channels/{board}/canvas/objects/batch"),
        root,
        json!({ "objects": [
            {
                "id": Uuid::now_v7().to_string(),
                "kind": "stroke",
                "x": 300.0, "y": 300.0, "w": 40.0, "h": 20.0,
                "props": { "points": [0.0, 0.0, 40.0, 20.0], "width": 3.0, "color": "annotation" },
            },
            {
                "id": left,
                "kind": "note",
                "x": 400.0, "y": 300.0, "w": 100.0, "h": 50.0,
                "props": { "text": "n" },
            },
            {
                "id": right,
                "kind": "note",
                "x": 600.0, "y": 300.0, "w": 100.0, "h": 50.0,
                "props": { "text": "n" },
            },
            {
                "id": Uuid::now_v7().to_string(),
                "kind": "edge",
                "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0,
                "props": {
                    "from": { "object_id": left, "side": "right" },
                    "to": { "object_id": right, "side": "left" },
                    "arrow": "end",
                },
            },
        ] }),
    )
    .await;
    // A member may not remove another's object: the 403 names the permission it lacked.
    c.refuses(
        "submitCanvasOp",
        "POST",
        &format!("/channels/{board}/canvas/ops"),
        Some(member),
        Payload::Json(json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "remove",
            "object_ids": [first_object_id],
        })),
    )
    .await;
}
