// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The calls that end things, on throwaway accounts: a member's timeout,
//! removal and restore, the bulk member operations, account deletion,
//! admin-issued recovery, the second factor, bots and webhooks.
//!
//! Its own module to make room in `script.rs`, which sits at its hard line
//! ceiling, the same reason `admin_recovery.rs` was split out of it; this was
//! the last self-contained block left.

use serde_json::json;
use uuid::Uuid;

use crate::response_contract::world::{Contract, Payload};

use super::admin_recovery::recovery_calls;
use super::bots::bot_calls;
use super::members_bulk::bulk_member_calls;
use super::totp_calls::totp_calls;
use super::webhooks::webhook_calls;
use super::{member_account, signup, text};

/// The calls that end a session or an account, on throwaway accounts so
/// nothing above depends on what they destroy. `resetPassword` is last of all
/// because it revokes every session the account it recovers still holds.
pub(crate) async fn farewell_calls(
    c: &mut Contract,
    root: &str,
    bob_id: &str,
    code: &str,
    channel: &str,
) {
    let carol = c
        .call(
            "register",
            "POST",
            "/auth/register",
            None,
            Payload::Json(signup("carol", "desktop", Some(code))),
        )
        .await;
    c.bare(
        "logout",
        "POST",
        "/auth/logout",
        &text(&carol, "access_token"),
    )
    .await;

    // Dave writes before leaving, so the later listing carries the anonymized author shape nothing else here produces.
    let dave = c
        .call(
            "register",
            "POST",
            "/auth/register",
            None,
            Payload::Json(signup("dave", "desktop", Some(code))),
        )
        .await;
    let dave_token = text(&dave, "access_token");
    let messages = format!("/channels/{channel}/messages");
    c.json(
        "sendMessage",
        "POST",
        &messages,
        &dave_token,
        json!({ "id": Uuid::now_v7().to_string(), "content": "written before leaving" }),
    )
    .await;
    c.json(
        "deleteAccount",
        "DELETE",
        "/account",
        &dave_token,
        json!({ "password": super::PASSWORD }),
    )
    .await;
    c.get("listMessages", &format!("{messages}?limit=50"), root)
        .await;

    // Erin exists only to be moderated: a removal revokes the target's sessions.
    let erin = c
        .call(
            "register",
            "POST",
            "/auth/register",
            None,
            Payload::Json(signup("erin", "desktop", Some(code))),
        )
        .await;
    let erin_id = text(&erin, "user_id");
    c.json(
        "timeOutMember",
        "PUT",
        &format!("/members/{erin_id}/timeout"),
        root,
        json!({ "duration_seconds": 300, "reason": "contract" }),
    )
    .await;
    c.bare(
        "liftMemberTimeout",
        "DELETE",
        &format!("/members/{erin_id}/timeout"),
        root,
    )
    .await;
    c.json(
        "removeMember",
        "PUT",
        &format!("/members/{erin_id}/removal"),
        root,
        json!({ "reason": "contract" }),
    )
    .await;
    c.get("listRemovedMembers", "/members/removed", root).await;
    c.bare(
        "restoreMember",
        "DELETE",
        &format!("/members/{erin_id}/removal"),
        root,
    )
    .await;

    bulk_member_calls(c, root, &erin_id).await;

    member_account::nickname_calls(c, root, &erin_id).await;
    member_account::member_account_calls(c, root, code).await;

    recovery_calls(c, root, bob_id).await;
    totp_calls(c, root, code).await;
    bot_calls(c, root, channel).await;
    webhook_calls(c, root, channel).await;
}
