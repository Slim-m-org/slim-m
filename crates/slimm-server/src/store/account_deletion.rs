// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting an account: purge what is personal, keep what was shared, and
//! free the username.
//!
//! Split out of `sessions.rs` when that file crossed its recorded ceiling.
//! It is the natural seam - everything else there is about getting *into* an
//! account, and this is the one operation that ends one - and the file-budget
//! allowlist had named it as the obvious first split since the gate was
//! written.
//!
//! Not to be confused with [`super::removals`], which is a moderator taking
//! access away. That one deliberately leaves authorship intact; this one is
//! the account holder's own act and is the thing that anonymizes.

use crate::ids::{SessionId, UserId};

use super::moderation_audit::{ModerationAudit, record_moderation_audit};
use super::{Store, now_ms};

/// Why deleting an account was refused.
#[derive(Debug)]
pub enum DeleteAccountError {
    /// Doing it would leave other people in a deployment with no administrator
    /// and no way to appoint one.
    WouldStrandDeployment,
    /// The account does not exist, or has already been deleted.
    UserNotFound,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for DeleteAccountError {
    fn from(err: sqlx::Error) -> Self {
        DeleteAccountError::Internal(err.into())
    }
}

impl From<anyhow::Error> for DeleteAccountError {
    fn from(err: anyhow::Error) -> Self {
        DeleteAccountError::Internal(err)
    }
}
impl Store {
    /// Deletes an account end to end. Personal data (devices, sessions, tokens,
    /// reactions, read state, role memberships, member channel overwrites, reset
    /// codes, attachment uploader records) is purged; content left in shared
    /// scopes (messages, canvas) is kept but its authorship is cleared; and the
    /// user row is tombstoned and anonymized so the username frees up and login
    /// is impossible. Returns the sessions that were revoked so the caller can
    /// close their live sockets.
    ///
    /// Concurrency: the first statement is a write, so the transaction takes the
    /// write lock immediately (no stale-snapshot race) and a login racing this
    /// deletion serializes against it (see [`Store::open_session`]). A request
    /// already in flight on a still-valid token could commit one write just after
    /// this transaction; that content stays attributed to the now-anonymized
    /// tombstone, so it carries no identity, and the session is revoked so no
    /// further writes follow. Closing that last-write window fully would need a
    /// liveness check inside every write verb, left for later.
    ///
    /// Every authorship column is cleared here by hand, including
    /// `reports.reporter_id` and `reports.resolved_by`. Those two carry
    /// `ON DELETE SET NULL` in `0005_safety.sql` and it never fires: deletion
    /// here is a tombstone `UPDATE`, never a `DELETE FROM users`, so the
    /// constraint has nothing to trigger on. `ReportDto.reporter_id`'s own doc
    /// comment already promised "null once the reporter's account has been
    /// anonymized", which was not true of any code path until this cleared it.
    ///
    /// Group-ownership transfer is a no-op until an ownership model exists; the
    /// current schema has no owner column, so nothing can be orphaned.
    ///
    /// Refuses to delete the last administrator, because that leaves a
    /// deployment nobody can administer and no recovery path: roles, invites
    /// and moderation all need a bit no live account would hold any more.
    /// Every other path that can remove an administrator already checked this;
    /// account deletion was the one that did not.
    ///
    /// That refusal only applies while somebody would actually be stranded.
    /// The last user of a deployment deleting themselves leaves nobody to
    /// administer, but also nobody to care, and refusing there would trap the
    /// one person who most clearly has the right to leave.
    pub async fn delete_account(
        &self,
        user_id: UserId,
    ) -> Result<Vec<SessionId>, DeleteAccountError> {
        self.purge_account(user_id, None).await
    }

    /// [`Store::delete_account`] as an administrator's act on somebody else's
    /// account: the same purge, plus an `account_delete` row in the moderation
    /// audit log written in the same transaction, since nothing undoes it.
    pub async fn delete_account_by_admin(
        &self,
        user_id: UserId,
        deleted_by: UserId,
    ) -> Result<Vec<SessionId>, DeleteAccountError> {
        self.purge_account(user_id, Some(deleted_by)).await
    }

    async fn purge_account(
        &self,
        user_id: UserId,
        audited_by: Option<UserId>,
    ) -> Result<Vec<SessionId>, DeleteAccountError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let live = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM users WHERE id = ? AND deleted_at IS NULL"#,
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if live.is_none() {
            return Err(DeleteAccountError::UserNotFound);
        }

        // Deleting devices cascades these.
        let revoked: Vec<SessionId> = sqlx::query!(
            r#"UPDATE sessions SET revoked_at = ? WHERE user_id = ?
               RETURNING id AS "id!: SessionId""#,
            now,
            user_id
        )
        .fetch_all(&mut *tx)
        .await?
        .into_iter()
        .map(|row| row.id)
        .collect();

        // Anonymize authored content that stays visible to others.
        sqlx::query!(
            "UPDATE messages SET author_id = NULL WHERE author_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // A forward's snapshot stays visible to whoever it reached, so its author id goes the way a message's does.
        sqlx::query!(
            "UPDATE message_forwards SET origin_author_id = NULL WHERE origin_author_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE canvas_objects SET author_id = NULL WHERE author_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE canvas_ops SET actor_id = NULL WHERE actor_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE canvas_object_locks SET locked_by = NULL WHERE locked_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE canvas_audit_log SET actor_id = NULL WHERE actor_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE moderation_audit_log SET actor_id = NULL WHERE actor_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE message_ops SET actor_id = NULL WHERE actor_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE invites SET created_by = NULL WHERE created_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE password_reset_codes SET issued_by = NULL WHERE issued_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE reports SET reporter_id = NULL WHERE reporter_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE reports SET resolved_by = NULL WHERE resolved_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE reports SET snapshot_author_id = NULL WHERE snapshot_author_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE member_timeouts SET issued_by = NULL WHERE issued_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!("DELETE FROM member_nicknames WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!(
            "UPDATE member_nicknames SET set_by = NULL WHERE set_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE space_removals SET removed_by = NULL WHERE removed_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE polls SET created_by = NULL WHERE created_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // A shared code-block run stays visible to everyone who can see the message; its runner id goes the way a message author's does. The FK's ON DELETE SET NULL never fires on a tombstone UPDATE, so this clears it by hand.
        sqlx::query!(
            "UPDATE code_runs SET ran_by = NULL WHERE ran_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // A launched app surface stays visible to everyone in the channel; who launched it goes the way a poll's creator does, and for the same tombstone-UPDATE reason the FK never fires.
        sqlx::query!(
            "UPDATE app_surfaces SET created_by = NULL WHERE created_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // Who provisioned a bot is the provisioner's own data; the bot itself is a separate account and keeps working.
        sqlx::query!(
            "UPDATE bot_tokens SET created_by = NULL WHERE created_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // Same shape as bot_tokens.created_by: who minted a webhook is the minter's own data, and the webhook itself keeps delivering.
        sqlx::query!(
            "UPDATE webhooks SET created_by = NULL WHERE created_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // A call stays in the transcript the way any other message does; who placed it goes the way a launched app surface's creator does.
        sqlx::query!(
            "UPDATE call_records SET caller_id = NULL WHERE caller_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // schema/openapi.yaml promises both of these read null once the account is gone.
        sqlx::query!(
            "UPDATE pinned_messages SET pinned_by = NULL WHERE pinned_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE custom_emoji SET uploader_id = NULL WHERE uploader_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;

        // Purge personal data. Deleting devices cascades sessions and their tokens.
        sqlx::query!("DELETE FROM devices WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!("DELETE FROM reactions WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        // A mention marker names the account it was mentioning, not the message's own content - nothing left to anonymize.
        sqlx::query!("DELETE FROM message_mentions WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!("DELETE FROM read_states WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        // A slot names the participant, not who arranged it - nothing to anonymize once they are gone.
        sqlx::query!("DELETE FROM canvas_media_slots WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!("DELETE FROM member_roles WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        // A note is the author's own data, so it leaves with them; the subject's own deletion never touches it.
        sqlx::query!("DELETE FROM user_notes WHERE author_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        // Which DMs this account had closed out of its own sidebar is its own preference, not the other side's.
        sqlx::query!("DELETE FROM dm_hides WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!("DELETE FROM saved_messages WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        // How somebody voted is theirs, like the emoji they reacted with; the tally moves as a reaction count would.
        sqlx::query!("DELETE FROM poll_votes WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        // Both directions: a deleted account cannot come back to be blocked again.
        sqlx::query!(
            "DELETE FROM user_blocks WHERE blocker_id = ? OR blocked_id = ?",
            user_id,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // A real DELETE, so notification_schedule_days genuinely cascades from it.
        sqlx::query!(
            "DELETE FROM notification_schedules WHERE user_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // Both directions, like user_blocks above.
        sqlx::query!(
            "DELETE FROM notification_schedule_allowed_users WHERE user_id = ? OR allowed_user_id = ?",
            user_id,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "DELETE FROM notification_schedule_allowed_channels WHERE user_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "DELETE FROM channel_notification_prefs WHERE user_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // Which inviter's code this account joined with is theirs to forget too; the tombstone never fires its CASCADE.
        sqlx::query!("DELETE FROM invite_redemptions WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!(
            "DELETE FROM attachment_uploaders WHERE uploaded_by = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // A deleted bot's credential goes with it, or its hash outlives the account.
        sqlx::query!("DELETE FROM bot_tokens WHERE bot_user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        // A deleted bot's own registration: its own data, nobody else's, purged with it.
        sqlx::query!("DELETE FROM bot_commands WHERE bot_user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!(
            "DELETE FROM bot_command_registrations WHERE bot_user_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query("DELETE FROM bot_ui_entries WHERE bot_user_id = ?")
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM watch_sessions WHERE bot_user_id = ?")
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        // A controller hint naming a departed member would outlive them for the session's life.
        sqlx::query(
            "UPDATE watch_sessions SET controller_user_id = NULL WHERE controller_user_id = ?",
        )
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
        // The role itself stays; it may be shared with a human.
        sqlx::query!(
            "UPDATE roles SET managed_bot_id = NULL WHERE managed_bot_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // Same shape as bot_tokens.bot_user_id above: its own data, purged with it.
        sqlx::query!("DELETE FROM webhooks WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!(
            "DELETE FROM channel_overwrites WHERE target_type = 'member' AND target_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "DELETE FROM password_reset_codes WHERE user_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        // The factor row holds its secret in the clear; a tombstone fires no cascade.
        sqlx::query!("DELETE FROM totp_challenges WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!("DELETE FROM totp_recovery_codes WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!("DELETE FROM user_totp_factors WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query!(
            "DELETE FROM username_collision_renames WHERE user_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;

        // The live-username index excludes tombstones, so the name frees up.
        let tombstone = format!("deleted-{user_id}");
        sqlx::query!(
            "UPDATE users
             SET deleted_at = ?, is_anonymized = 1, password_hash = NULL,
                 username = ?, display_name = 'Deleted User'
             WHERE id = ?",
            now,
            tombstone,
            user_id
        )
        .execute(&mut *tx)
        .await?;

        // Refused only while somebody else would be stranded; see the note.
        if super::roles::administrator_count(&mut tx).await? == 0 {
            let others = sqlx::query_scalar!(
                r#"SELECT COUNT(*) AS "n!: i64" FROM users
                   WHERE deleted_at IS NULL AND id != ?"#,
                user_id
            )
            .fetch_one(&mut *tx)
            .await?;
            if others > 0 {
                return Err(DeleteAccountError::WouldStrandDeployment);
            }
        }

        if let Some(actor_id) = audited_by {
            record_moderation_audit(
                &mut tx,
                ModerationAudit {
                    actor_id,
                    subject_id: user_id,
                    action: "account_delete",
                    reason: None,
                    until: None,
                    created_at: now,
                },
            )
            .await?;
        }

        tx.commit().await?;
        Ok(revoked)
    }
}
