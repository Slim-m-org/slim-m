// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Role and channel-overwrite calls for `content.rs`, a sibling module
//! rather than folded into that already near-the-limit file - `content.rs`
//! was past the 500-line hard cap with the roles-and-permissions redesign's
//! reorderRoles and batchSetChannelOverwrites cases inline.

use serde_json::json;
use slimm_server::permissions::Permissions;

use super::text;
use crate::world::Contract;

/// Every role route: list, create, update, assign, unassign, a no-op
/// reorder (enough to check `reorderRoles`'s response shape without
/// disturbing anything else this scenario relies on), then delete.
pub(super) async fn role_calls(c: &mut Contract, root: &str, bob_id: &str) {
    c.get("listRoles", "/roles", root).await;
    let role = c
        .json(
            "createRole",
            "POST",
            "/roles",
            root,
            json!({ "name": "mods", "permissions": Permissions::VIEW_CHANNEL.bits() }),
        )
        .await;
    let role = text(&role, "id");
    c.json(
        "updateRole",
        "PATCH",
        &format!("/roles/{role}"),
        root,
        json!({ "name": "moderators" }),
    )
    .await;
    c.bare(
        "assignRole",
        "PUT",
        &format!("/members/{bob_id}/roles/{role}"),
        root,
    )
    .await;
    c.bare(
        "unassignRole",
        "DELETE",
        &format!("/members/{bob_id}/roles/{role}"),
        root,
    )
    .await;

    let live_roles = c.get("listRoles", "/roles", root).await;
    let role_ids: Vec<String> = live_roles
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| !r["is_everyone"].as_bool().unwrap_or(false))
        .map(|r| text(r, "id"))
        .collect();
    c.json(
        "reorderRoles",
        "PATCH",
        "/roles/reorder",
        root,
        json!({ "role_ids": role_ids }),
    )
    .await;

    c.bare("deleteRole", "DELETE", &format!("/roles/{role}"), root)
        .await;
}

/// Every channel-overwrite route: a single-target set, a batch set covering
/// the same target, a list, then a clear.
pub(super) async fn overwrite_calls(c: &mut Contract, root: &str, bob_id: &str, channel: &str) {
    let overwrite = format!("/channels/{channel}/overwrites/member/{bob_id}");
    c.json(
        "setChannelOverwrite",
        "PUT",
        &overwrite,
        root,
        json!({ "allow": Permissions::VIEW_CHANNEL.bits(), "deny": 0 }),
    )
    .await;
    c.json(
        "batchSetChannelOverwrites",
        "PUT",
        &format!("/channels/{channel}/overwrites"),
        root,
        json!({ "overwrites": [
            { "kind": "member", "id": bob_id, "allow": Permissions::VIEW_CHANNEL.bits(), "deny": 0 },
        ] }),
    )
    .await;
    c.get(
        "getChannelOverwrites",
        &format!("/channels/{channel}/overwrites"),
        root,
    )
    .await;
    c.bare("deleteChannelOverwrite", "DELETE", &overwrite, root)
        .await;
}

/// Category permissions (decision 0064): list, an empty batch, then a channel
/// created into the category and synced back to it.
pub(super) async fn category_overwrite_calls(c: &mut Contract, root: &str, category_id: &str) {
    let uri = format!("/categories/{category_id}/overwrites");
    c.get("getCategoryOverwrites", &uri, root).await;
    c.json(
        "batchSetCategoryOverwrites",
        "PUT",
        &uri,
        root,
        json!({ "overwrites": [] }),
    )
    .await;
    let channel = c
        .json(
            "createChannel",
            "POST",
            "/channels",
            root,
            json!({ "name": "filed", "category_id": category_id }),
        )
        .await;
    c.bare(
        "syncChannelOverwrites",
        "POST",
        &format!("/channels/{}/overwrites/sync", text(&channel, "id")),
        root,
    )
    .await;
}
