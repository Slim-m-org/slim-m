// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `moderation_audit_log`: one row per removal, restore, timeout and lift,
//! written in the same transaction as the state change it records.
//!
//! `space_removals` and `member_timeouts` hold one row per member and answer
//! only "is this in force right now" - a restore deletes the removal it
//! reverses, and a re-issued timeout overwrites the one it replaces. This
//! table is where the acts themselves accumulate, so that neither of those
//! tables has to grow a soft-delete every in-force query would then have to
//! learn to skip. See the migration's own comment for that reasoning.
//!
//! `/reports/history` (`store/moderation_history.rs`) reads it over HTTP,
//! merged with resolved reports into one feed.

use crate::ids::UserId;

/// Every act the audit log records. The table's own CHECK no longer lists
/// them (migration 0118), so this enum is the one place a new act is added:
/// no table rebuild, and no free-text action can reach the log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ModerationAction {
    Remove,
    Restore,
    Timeout,
    TimeoutCleared,
    MessagesDeleted,
    BotCreate,
    BotRevoke,
    BotPermissionGrant,
    WebhookCreate,
    WebhookRevoke,
    WebhookRotate,
    TotpCleared,
    AccountDelete,
    ResetCodeIssue,
    NicknameSet,
    NicknameClear,
}

impl ModerationAction {
    pub(crate) const ALL: [Self; 16] = [
        Self::Remove,
        Self::Restore,
        Self::Timeout,
        Self::TimeoutCleared,
        Self::MessagesDeleted,
        Self::BotCreate,
        Self::BotRevoke,
        Self::BotPermissionGrant,
        Self::WebhookCreate,
        Self::WebhookRevoke,
        Self::WebhookRotate,
        Self::TotpCleared,
        Self::AccountDelete,
        Self::ResetCodeIssue,
        Self::NicknameSet,
        Self::NicknameClear,
    ];

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Remove => "remove",
            Self::Restore => "restore",
            Self::Timeout => "timeout",
            Self::TimeoutCleared => "timeout_cleared",
            Self::MessagesDeleted => "messages_deleted",
            Self::BotCreate => "bot_create",
            Self::BotRevoke => "bot_revoke",
            Self::BotPermissionGrant => "bot_permission_grant",
            Self::WebhookCreate => "webhook_create",
            Self::WebhookRevoke => "webhook_revoke",
            Self::WebhookRotate => "webhook_rotate",
            Self::TotpCleared => "totp_cleared",
            Self::AccountDelete => "account_delete",
            Self::ResetCodeIssue => "reset_code_issue",
            Self::NicknameSet => "nickname_set",
            Self::NicknameClear => "nickname_clear",
        }
    }
}

/// One moderation act, as it is written down.
///
/// `until` is the deadline the act concerns: the new one for a `timeout`, the
/// one cut short for a `timeout_cleared`, and absent for a removal or restore.
pub(super) struct ModerationAudit<'a> {
    pub(super) actor_id: UserId,
    pub(super) subject_id: UserId,
    pub(super) action: ModerationAction,
    pub(super) reason: Option<&'a str>,
    pub(super) until: Option<i64>,
    pub(super) created_at: i64,
}

/// Appends one audit row.
///
/// Takes a connection rather than the transaction itself so a caller can pass
/// `&mut *tx` and have the audit commit or roll back with the act it records;
/// a moderation change that lands without its trail, or a trail without its
/// change, is worse than either failing.
pub(super) async fn record_moderation_audit(
    conn: &mut sqlx::SqliteConnection,
    entry: ModerationAudit<'_>,
) -> Result<(), sqlx::Error> {
    let action = entry.action.as_str();
    sqlx::query!(
        r#"INSERT INTO moderation_audit_log
               (actor_id, subject_id, action, reason, until, created_at)
           VALUES (?, ?, ?, ?, ?, ?)"#,
        entry.actor_id,
        entry.subject_id,
        action,
        entry.reason,
        entry.until,
        entry.created_at
    )
    .execute(&mut *conn)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::ModerationAction;

    /// The schema documents the action enum clients switch on; a variant
    /// added here without it would reach clients undocumented.
    #[test]
    fn every_action_is_in_the_schema_and_nothing_else_is() {
        let text = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../schema/openapi.yaml"
        ))
        .unwrap();
        let schema: serde_json::Value = serde_saphyr::from_str_with_options(
            &text,
            serde_saphyr::options! { strict_booleans: true },
        )
        .unwrap();
        let documented: Vec<&str> =
            schema["components"]["schemas"]["AuditLogHistoryEntry"]["properties"]["action"]["enum"]
                .as_array()
                .expect("AuditLogHistoryEntry.action enum")
                .iter()
                .map(|v| v.as_str().unwrap())
                .collect();
        let mut ours: Vec<&str> = ModerationAction::ALL.iter().map(|a| a.as_str()).collect();
        let mut theirs = documented.clone();
        ours.sort_unstable();
        theirs.sort_unstable();
        assert_eq!(ours, theirs);
    }
}
