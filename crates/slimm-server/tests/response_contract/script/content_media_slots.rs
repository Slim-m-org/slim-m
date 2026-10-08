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
