// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas media-slot calls for `content.rs`'s own `channel_calls`, a sibling
//! module rather than folded into that already near-the-limit function -
//! `content.rs` was 505 lines with this inline, over the 500-line hard cap.

use serde_json::json;
use uuid::Uuid;

use super::text;
use crate::world::Contract;

/// Named for bob, not root, so this also exercises the no-own-tile gate:
/// anyone with USE_CANVAS may arrange anyone's media slot.
pub(super) async fn media_slot_calls(c: &mut Contract, root: &str, channel: &str, bob_id: &str) {
    c.json(
        "putCanvasMediaSlot",
        "PUT",
        &format!("/channels/{channel}/canvas/media-slots/screen/{bob_id}"),
        root,
        json!({
            "x": 40.0, "y": 40.0, "w": 360.0, "h": 203.0,
            "locked": false, "sent_to_back": false,
        }),
    )
    .await;
    c.get(
        "listCanvasMediaSlots",
        &format!("/channels/{channel}/canvas/media-slots"),
        root,
    )
    .await;
}

/// Locks a fresh stroke, lists the locks, then unlocks it.
pub(super) async fn object_lock_calls(c: &mut Contract, root: &str, channel: &str) {
    let placed = c
        .json(
            "placeCanvasObject",
            "POST",
            &format!("/channels/{channel}/canvas/objects"),
            root,
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "stroke",
                "x": 300.0, "y": 300.0, "w": 40.0, "h": 20.0,
                "props": { "points": [0.0, 0.0, 40.0, 20.0], "width": 3.0, "color": "annotation" },
            }),
        )
        .await;
    let object = text(&placed, "id");
    let lock = format!("/channels/{channel}/canvas/objects/{object}/lock");
    c.bare("lockCanvasObject", "PUT", &lock, root).await;
    c.get(
        "listCanvasObjectLocks",
        &format!("/channels/{channel}/canvas/object-locks"),
        root,
    )
    .await;
    c.bare("unlockCanvasObject", "DELETE", &lock, root).await;
}

/// An edit, a locked-object clear (served as `clear_scoped`), a paged viewport read and a purge.
pub(super) async fn canvas_more_calls(c: &mut Contract, root: &str, channel: &str) {
    let objects = format!("/channels/{channel}/canvas/objects");
    let ops = format!("/channels/{channel}/canvas/ops");
    let note = c
        .json(
            "placeCanvasObject",
            "POST",
            &objects,
            root,
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "note",
                "x": 500.0, "y": 500.0, "w": 220.0, "h": 140.0,
                "props": { "text": "before", "color": "annotation" },
            }),
        )
        .await;
    let note_id = text(&note, "id");
    c.json(
        "submitCanvasOp",
        "POST",
        &ops,
        root,
        json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "edit",
            "object_id": note_id,
            "props": { "text": "after", "color": "annotation" },
        }),
    )
    .await;

    // The note is pinned, so a clear of notes spares it and a second one takes it.
    c.bare(
        "lockCanvasObject",
        "PUT",
        &format!("{objects}/{note_id}/lock"),
        root,
    )
    .await;
    let head = note["seq"].as_i64().unwrap_or(0);
    let scoped = |kinds: &[&str]| {
        json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "clear_scoped",
            "before_seq": head,
            "kinds": kinds,
        })
    };
    c.json(
        "submitCanvasOp",
        "POST",
        &ops,
        root,
        scoped(&["note", "shape"]),
    )
    .await;
    c.get("listCanvasOps", &format!("{ops}?after_seq=0"), root)
        .await;

    c.get(
        "listCanvasViewport",
        &format!("{objects}?min_x=-1000&min_y=-1000&max_x=2000&max_y=2000&cursor_seq=0&limit=1"),
        root,
    )
    .await;
    c.bare(
        "purgeCanvasObject",
        "DELETE",
        &format!("{objects}/{note_id}"),
        root,
    )
    .await;
}
