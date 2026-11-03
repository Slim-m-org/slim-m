// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The table of audited admin routes: one line per change the log records.

use axum::http::Method;

/// One audited route: its method and axum template, the action it records,
/// and which path parameter names the thing changed. `None` reads the id
/// from the response instead, for creates.
pub struct AuditedRoute {
    pub method: Method,
    pub path: &'static str,
    pub action: &'static str,
    pub target: Option<&'static str>,
}

const fn route(
    method: Method,
    path: &'static str,
    action: &'static str,
    target: Option<&'static str>,
) -> AuditedRoute {
    AuditedRoute {
        method,
        path,
        action,
        target,
    }
}

const CH: Option<&str> = Some("channel_id");
const CAT: Option<&str> = Some("category_id");
const ROLE: Option<&str> = Some("role_id");
const MODULE: Option<&str> = Some("id");

/// Every admin change the log records.
pub const AUDITED_ROUTES: &[AuditedRoute] = &[
    route(Method::PATCH, "/space/settings", "space.update", None),
    route(Method::PUT, "/space/join-gate", "space.join_gate", None),
    route(
        Method::POST,
        "/space/uplink-test",
        "space.uplink_test",
        None,
    ),
    route(Method::PATCH, "/space/analytics", "space.analytics", None),
    route(Method::PATCH, "/space/retention", "space.retention", None),
    route(Method::PATCH, "/space/canvas-cap", "space.canvas_cap", None),
    route(
        Method::PATCH,
        "/space/screen-share",
        "space.screen_share",
        None,
    ),
    route(
        Method::PATCH,
        "/space/attachment-limit",
        "space.attachment_limit",
        None,
    ),
    route(
        Method::PATCH,
        "/space/media-compression",
        "space.media_compression",
        None,
    ),
    route(
        Method::PATCH,
        "/space/link-previews",
        "space.link_previews",
        None,
    ),
    route(
        Method::POST,
        "/space/setup/complete",
        "space.setup_complete",
        None,
    ),
    route(Method::POST, "/space/icon", "space.icon_set", None),
    route(Method::DELETE, "/space/icon", "space.icon_clear", None),
    route(Method::POST, "/space/banner", "space.banner_set", None),
    route(Method::DELETE, "/space/banner", "space.banner_clear", None),
    route(Method::POST, "/exports/space", "space.export", None),
    route(Method::POST, "/roles", "role.create", None),
    route(Method::PATCH, "/roles/reorder", "role.reorder", None),
    route(Method::PATCH, "/roles/{role_id}", "role.update", ROLE),
    route(Method::DELETE, "/roles/{role_id}", "role.delete", ROLE),
    route(
        Method::PUT,
        "/members/{user_id}/roles/{role_id}",
        "role.assign",
        Some("user_id"),
    ),
    route(
        Method::DELETE,
        "/members/{user_id}/roles/{role_id}",
        "role.unassign",
        Some("user_id"),
    ),
    route(
        Method::PUT,
        "/roles/{role_id}/module-permissions/{module_id}/{perm_key}",
        "role.module_grant",
        ROLE,
    ),
    route(
        Method::DELETE,
        "/roles/{role_id}/module-permissions/{module_id}/{perm_key}",
        "role.module_revoke",
        ROLE,
    ),
    route(
        Method::PATCH,
        "/bots/{bot_id}/prefix",
        "bot.prefix",
        Some("bot_id"),
    ),
    route(Method::POST, "/channels", "channel.create", None),
    route(Method::PUT, "/channels/order", "channel.reorder", None),
    route(
        Method::PATCH,
        "/channels/{channel_id}",
        "channel.update",
        CH,
    ),
    route(
        Method::DELETE,
        "/channels/{channel_id}",
        "channel.delete",
        CH,
    ),
    route(
        Method::PUT,
        "/channels/{channel_id}/retention",
        "channel.retention",
        CH,
    ),
    route(
        Method::PATCH,
        "/channels/{channel_id}/room",
        "channel.room",
        CH,
    ),
    route(
        Method::PUT,
        "/channels/{channel_id}/overwrites",
        "channel.overwrites",
        CH,
    ),
    route(
        Method::POST,
        "/channels/{channel_id}/overwrites/sync",
        "channel.overwrites_sync",
        CH,
    ),
    route(
        Method::PUT,
        "/channels/{channel_id}/overwrites/{kind}/{id}",
        "channel.overwrite_set",
        CH,
    ),
    route(
        Method::DELETE,
        "/channels/{channel_id}/overwrites/{kind}/{id}",
        "channel.overwrite_clear",
        CH,
    ),
    route(Method::POST, "/categories", "category.create", None),
    route(
        Method::PATCH,
        "/categories/{category_id}",
        "category.update",
        CAT,
    ),
    route(
        Method::DELETE,
        "/categories/{category_id}",
        "category.delete",
        CAT,
    ),
    route(
        Method::PUT,
        "/categories/{category_id}/overwrites",
        "category.overwrites",
        CAT,
    ),
    route(Method::POST, "/invites", "invite.create", None),
    route(
        Method::DELETE,
        "/invites/{code}",
        "invite.revoke",
        Some("code"),
    ),
    route(Method::POST, "/emoji", "emoji.create", None),
    route(Method::POST, "/emoji/bulk", "emoji.bulk_create", None),
    route(
        Method::DELETE,
        "/emoji/{emoji_id}",
        "emoji.delete",
        Some("emoji_id"),
    ),
    route(
        Method::POST,
        "/space/dock/modules/{id}/install",
        "module.install",
        MODULE,
    ),
    route(
        Method::POST,
        "/space/dock/packages/install",
        "module.install_file",
        None,
    ),
    route(
        Method::DELETE,
        "/space/dock/modules/{id}/install",
        "module.uninstall",
        MODULE,
    ),
    route(
        Method::POST,
        "/space/dock/modules/{id}/enable",
        "module.enable",
        MODULE,
    ),
    route(
        Method::POST,
        "/space/dock/modules/{id}/disable",
        "module.disable",
        MODULE,
    ),
    route(
        Method::DELETE,
        "/space/dock/modules/{id}/storage",
        "module.clear_storage",
        MODULE,
    ),
    route(
        Method::PUT,
        "/space/dock/modules/{id}/schedule-channel",
        "module.schedule_channel",
        MODULE,
    ),
    route(
        Method::PUT,
        "/space/dock/modules/{id}/call-audio-channels",
        "module.call_audio_channels",
        MODULE,
    ),
    route(
        Method::PUT,
        "/space/dock/modules/{id}/settings",
        "module.settings",
        MODULE,
    ),
    route(
        Method::PUT,
        "/space/dock/modules/{id}/hooks",
        "module.hook",
        MODULE,
    ),
    route(
        Method::POST,
        "/space/dock/sources",
        "module_source.add",
        None,
    ),
    route(
        Method::DELETE,
        "/space/dock/sources/{sourceId}",
        "module_source.remove",
        Some("sourceId"),
    ),
];
