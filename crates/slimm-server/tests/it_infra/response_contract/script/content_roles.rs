// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Role and channel-overwrite calls for `content.rs`, a sibling module
//! rather than folded into that already near-the-limit file - `content.rs`
//! was past the 500-line hard cap with the roles-and-permissions redesign's
//! reorderRoles and batchSetChannelOverwrites cases inline.

use serde_json::json;
use slimm_server::permissions::Permissions;

use super::text;
use crate::response_contract::world::Contract;

/// Every role route: list, create, update, preview, assign, unassign, a no-op
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
    c.get("previewRole", &format!("/roles/{role}/preview"), root)
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
    sub_category_calls(c, root, category_id).await;
}

/// Nested categories (decision 0120): a sub-category under `parent`, a move
/// out and back, its sync with the parent, and the arrangement written back
/// unchanged.
async fn sub_category_calls(c: &mut Contract, root: &str, parent: &str) {
    let sub = c
        .json(
            "createCategory",
            "POST",
            "/categories",
            root,
            json!({ "name": "nested", "parent_id": parent }),
        )
        .await;
    let sub = text(&sub, "id");
    let uri = format!("/categories/{sub}");
    c.json(
        "updateCategory",
        "PATCH",
        &uri,
        root,
        json!({ "parent_id": null }),
    )
    .await;
    c.json(
        "updateCategory",
        "PATCH",
        &uri,
        root,
        json!({ "parent_id": parent }),
    )
    .await;
    c.bare(
        "syncCategoryOverwrites",
        "POST",
        &format!("/categories/{sub}/overwrites/sync"),
        root,
    )
    .await;
    let listed = c.get("listCategories", "/categories", root).await;
    let mut groups: Vec<(serde_json::Value, Vec<String>)> = vec![(json!(null), Vec::new())];
    for category in listed.as_array().unwrap() {
        let parent = category["parent_id"].clone();
        match groups.iter_mut().find(|(p, _)| *p == parent) {
            Some((_, ids)) => ids.push(text(category, "id")),
            None => groups.push((parent, vec![text(category, "id")])),
        }
    }
    let groups: Vec<_> = groups
        .into_iter()
        .map(|(parent, ids)| json!({ "parent_id": parent, "category_ids": ids }))
        .collect();
    c.json(
        "reorderCategories",
        "PUT",
        "/categories/order",
        root,
        json!({ "groups": groups }),
    )
    .await;
}
