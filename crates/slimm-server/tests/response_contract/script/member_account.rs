// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An administrator deleting somebody else's account, a separate module for
//! the same reason `members_bulk.rs` is: adding it inline pushed `script.rs`
//! past the 500-line hard cap.

use super::super::script::{signup, text};
use crate::world::{Contract, Payload};

/// Registers a member who exists only to be deleted by somebody else.
///
/// Its own person rather than reusing one above, because this ends an account
/// for good: every later call in the script still expects the others to be
/// there. Distinct from `deleteAccount`, which is a person ending their own.
pub(super) async fn member_account_calls(c: &mut Contract, root: &str, code: &str) {
    let frank = c
        .call(
            "register",
            "POST",
            "/auth/register",
            None,
            Payload::Json(signup("frank", "desktop", Some(code))),
        )
        .await;
    let frank_id = text(&frank, "user_id");
    c.json(
        "changePassword",
        "POST",
        "/auth/password",
        &text(&frank, "access_token"),
        serde_json::json!({
            "current_password": super::super::script::PASSWORD,
            "new_password": "a-brand-new-passphrase",
        }),
    )
    .await;
    c.bare(
        "deleteMemberAccount",
        "DELETE",
        &format!("/members/{frank_id}/account"),
        root,
    )
    .await;
}

/// Gives a member a space-local name and takes it away again, so the
/// `UserProfile` the later calls read is back to the account's own name.
pub(super) async fn nickname_calls(c: &mut Contract, root: &str, member_id: &str) {
    c.json(
        "setMemberNickname",
        "PUT",
        &format!("/members/{member_id}/nickname"),
        root,
        serde_json::json!({ "nickname": "Contract Nick" }),
    )
    .await;
    c.bare(
        "clearMemberNickname",
        "DELETE",
        &format!("/members/{member_id}/nickname"),
        root,
    )
    .await;
}
