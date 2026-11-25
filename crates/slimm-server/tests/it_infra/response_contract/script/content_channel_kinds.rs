// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas channels and the voice canvas toggle for `content.rs`'s channel calls (decision 0139).

use serde_json::json;

use super::text;
use crate::response_contract::world::Contract;

/// Creates a voice channel whose canvas is off and discards its board, then a canvas channel with a call, and returns the canvas channel's id.
pub(super) async fn canvas_kind_calls(c: &mut Contract, root: &str) -> String {
    let call = c
        .json(
            "createChannel",
            "POST",
            "/channels",
            root,
            json!({ "name": "contract-call", "kind": "voice", "canvas_enabled": false }),
        )
        .await;
    c.json(
        "updateChannel",
        "PATCH",
        &format!("/channels/{}", text(&call, "id")),
        root,
        json!({ "discard_canvas": true }),
    )
    .await;
    let board = c
        .json(
            "createChannel",
            "POST",
            "/channels",
            root,
            json!({ "name": "contract-board", "kind": "canvas", "voice_enabled": true }),
        )
        .await;
    text(&board, "id")
}
