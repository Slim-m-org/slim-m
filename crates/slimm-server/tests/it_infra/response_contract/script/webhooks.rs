// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Webhook admin surface and delivery, in call order: mint through the real
//! `POST /webhooks` route, list, deliver both documented success shapes,
//! rename, revoke. Minting through the HTTP route rather than the store
//! directly, unlike this file's stage-4 predecessor, now that the admin
//! surface exists.

use serde_json::json;

use crate::response_contract::world::{Contract, Payload};

use super::text;

/// Drives create, list, both delivery shapes, rename and revoke, plus a
/// Discord-shaped `embeds` block that must never turn into a 400.
pub(crate) async fn webhook_calls(c: &mut Contract, root: &str, channel: &str) {
    let created = c
        .json(
            "createWebhook",
            "POST",
            "/webhooks",
            root,
            json!({ "channel_id": channel, "label": "alerts" }),
        )
        .await;
    c.get("listWebhooks", "/webhooks", root).await;

    let webhook_id = text(&created["webhook"], "id");
    let path = text(&created, "delivery_path");

    c.call(
        "deliverWebhook",
        "POST",
        &path,
        None,
        Payload::Json(json!({
            "content": "an alert fired",
            "embeds": [{"title": "discarded in this stage"}],
        })),
    )
    .await;

    c.call(
        "deliverWebhook",
        "POST",
        &format!("{path}?wait=true"),
        None,
        Payload::Json(json!({ "content": "another alert", "username": "monitor" })),
    )
    .await;

    c.json(
        "renameWebhook",
        "PATCH",
        &format!("/webhooks/{webhook_id}"),
        root,
        json!({ "label": "renamed-alerts" }),
    )
    .await;
    c.bare(
        "rotateWebhook",
        "POST",
        &format!("/webhooks/{webhook_id}/rotate"),
        root,
    )
    .await;
    c.bare(
        "revokeWebhook",
        "POST",
        &format!("/webhooks/{webhook_id}/revoke"),
        root,
    )
    .await;
}
