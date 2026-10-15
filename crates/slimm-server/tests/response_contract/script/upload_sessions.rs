// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resumable uploads end to end, one discarded and one completed, and the
//! admin's attachment size limit read, changed and cleared.

use serde_json::json;

use super::{PNG, text};
use crate::world::{Contract, Payload};

pub(super) async fn upload_session_calls(c: &mut Contract, root: &str) {
    let open = json!({"filename": "big.png", "size": PNG.len()});
    let dropped = c
        .json(
            "createUploadSession",
            "POST",
            "/attachments/uploads",
            root,
            open.clone(),
        )
        .await;
    c.bare(
        "discardUploadSession",
        "DELETE",
        &format!("/attachments/uploads/{}", text(&dropped, "id")),
        root,
    )
    .await;

    let session = c
        .json(
            "createUploadSession",
            "POST",
            "/attachments/uploads",
            root,
            open,
        )
        .await;
    let id = text(&session, "id");
    c.call(
        "appendUploadPart",
        "PUT",
        &format!("/attachments/uploads/{id}?offset=0"),
        Some(root),
        Payload::Bytes(PNG.to_vec()),
    )
    .await;
    c.get(
        "getUploadSession",
        &format!("/attachments/uploads/{id}"),
        root,
    )
    .await;
    c.bare(
        "completeUploadSession",
        "POST",
        &format!("/attachments/uploads/{id}/complete"),
        root,
    )
    .await;

    c.get("getSpaceAttachmentLimit", "/space/attachment-limit", root)
        .await;
    c.json(
        "updateSpaceAttachmentLimit",
        "PATCH",
        "/space/attachment-limit",
        root,
        json!({"max_bytes": 0}),
    )
    .await;
}
