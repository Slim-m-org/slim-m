// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Dock's full documented surface: browse the marketplace, install,
//! enable, disable and uninstall a module, and grant/revoke the permission
//! it registers. The fake registry `world.rs` stands up serves one module,
//! `code-exec`, with the real shape (see docs/decisions/0021), so every call
//! here reaches a genuine 2xx rather than a 501 or 502.

use serde_json::json;
use uuid::Uuid;

use super::text;
use crate::world::Contract;

pub(super) async fn dock_calls(c: &mut Contract, root: &str, admin_id: &str, channel: &str) {
    let modules = c.get("listDockModules", "/space/dock/modules", root).await;
    let id = text(&modules.as_array().expect("an array")[0], "id");

    let manifest = c
        .get("getDockModule", &format!("/space/dock/modules/{id}"), root)
        .await;
    let version = text(&manifest, "version");

    c.json(
        "installDockModule",
        "POST",
        &format!("/space/dock/modules/{id}/install"),
        root,
        json!({ "version": version }),
    )
    .await;

    c.get("listInstalledDockModules", "/space/dock/installed", root)
        .await;
    // Approving schedule gives the module its principal, so a channel can be chosen for it.
    c.json(
        "installDockModule",
        "POST",
        &format!("/space/dock/modules/{id}/install"),
        root,
        json!({ "version": version, "approved_host_capabilities": ["schedule"] }),
    )
    .await;
    c.json(
        "setDockModuleScheduleChannel",
        "PUT",
        &format!("/space/dock/modules/{id}/schedule-channel"),
        root,
        json!({ "channel_id": channel }),
    )
    .await;
    c.bare(
        "enableDockModule",
        "POST",
        &format!("/space/dock/modules/{id}/enable"),
        root,
    )
    .await;

    c.get("listModulePermissions", "/roles/module-permissions", root)
        .await;

    let role = c
        .json(
            "createRole",
            "POST",
            "/roles",
            root,
            json!({ "name": "dock-testers", "permissions": 0 }),
        )
        .await;
    let role_id = text(&role, "id");

    c.get(
        "listRoleModulePermissions",
        &format!("/roles/{role_id}/module-permissions"),
        root,
    )
    .await;
    c.bare(
        "grantModulePermission",
        "PUT",
        &format!("/roles/{role_id}/module-permissions/{id}/run"),
        root,
    )
    .await;

    // ADMINISTRATOR does not carry module permissions (decision 0021), so the admin needs the role assigned to actually hold `run`.
    c.bare(
        "assignRole",
        "PUT",
        &format!("/members/{admin_id}/roles/{role_id}"),
        root,
    )
    .await;
    c.json(
        "runModuleCommand",
        "POST",
        &format!("/modules/{id}/commands/run"),
        root,
        json!({ "input": "hello" }),
    )
    .await;
    // A shared code-block run (stored + broadcast, unlike runModuleCommand): the admin holds `run` and can view, so it is a real 200.
    let msg = c
        .json(
            "sendMessage",
            "POST",
            &format!("/channels/{channel}/messages"),
            root,
            json!({ "id": Uuid::now_v7().to_string(), "content": "```js\nx\n```" }),
        )
        .await;
    let msg_id = text(&msg, "id");
    c.json(
        "runCodeBlock",
        "POST",
        &format!("/messages/{msg_id}/blocks/0/run"),
        root,
        json!({ "module_id": id, "command": "run", "input": "x" }),
    )
    .await;

    // The admin now holds `run`, so this comes back a real pair to validate against CodeBlockRunner, not just the empty-list case.
    c.get("listCodeBlockRunners", "/modules/code-block-runners", root)
        .await;
    // code-exec declares no slash-command, so this is the empty-list shape; the populated shape is validated in tests/module_slash_commands.rs.
    c.get("listSlashCommands", "/modules/slash-commands", root)
        .await;
    // code-exec declares an `app` extension point and the admin holds `run`, so this is a real populated App list.
    c.get("listApps", "/modules/apps", root).await;
    // Launching an app is a message send; the admin holds `run` and can view, so a real 200 carrying the Message with its app_surface.
    c.json(
        "launchAppMessage",
        "POST",
        &format!("/channels/{channel}/messages/apps"),
        root,
        json!({ "id": Uuid::now_v7().to_string(), "module_id": id, "command": "run" }),
    )
    .await;
    c.bare(
        "unassignRole",
        "DELETE",
        &format!("/members/{admin_id}/roles/{role_id}"),
        root,
    )
    .await;

    c.bare(
        "revokeModulePermission",
        "DELETE",
        &format!("/roles/{role_id}/module-permissions/{id}/run"),
        root,
    )
    .await;
    c.bare("deleteRole", "DELETE", &format!("/roles/{role_id}"), root)
        .await;

    let source = c
        .json(
            "addDockSource",
            "POST",
            "/space/dock/sources",
            root,
            json!({ "repo": "acme/mods" }),
        )
        .await;
    let source_id = text(&source, "id");
    c.get("listDockSources", "/space/dock/sources", root).await;
    c.bare(
        "removeDockSource",
        "DELETE",
        &format!("/space/dock/sources/{source_id}"),
        root,
    )
    .await;

    c.bare(
        "disableDockModule",
        "POST",
        &format!("/space/dock/modules/{id}/disable"),
        root,
    )
    .await;
    c.bare(
        "clearDockModuleStorage",
        "DELETE",
        &format!("/space/dock/modules/{id}/storage"),
        root,
    )
    .await;
    c.bare(
        "uninstallDockModule",
        "DELETE",
        &format!("/space/dock/modules/{id}/install"),
        root,
    )
    .await;
}
