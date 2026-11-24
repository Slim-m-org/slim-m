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

/// One checked statement run on the deletion transaction.
macro_rules! exec {
    ($tx:expr, $sql:literal $(, $arg:expr)* $(,)?) => {
        sqlx::query!($sql $(, $arg)*).execute(&mut **$tx).await?
    };
}

mod anonymize;
mod blocked_authorship;
mod bounded;
mod personal;

pub(super) use blocked_authorship::forget_unblocked_author;
pub use bounded::Cleared;

use crate::ids::{ChannelId, MessageId, SessionId, UserId};

use super::moderation_audit::{ModerationAction, ModerationAudit, record_moderation_audit};
use super::space_owner::Handoff;
use super::{Store, now_ms};

/// What a deletion leaves the caller to announce.
#[derive(Debug)]
pub struct DeletedAccount {
    /// Every session the account had, so their sockets close.
    pub revoked: Vec<SessionId>,
    /// Set when the account owned the Space and ownership passed on.
    pub handoff: Option<Handoff>,
    /// Messages whose reaction tallies lost this account's reactions.
    pub reactions_changed: Vec<(ChannelId, MessageId)>,
    /// Polls whose tallies lost this account's vote.
    pub polls_changed: Vec<(ChannelId, MessageId)>,
    /// Temporary rooms this account owned, now ownerless and renamed.
    pub rooms_renamed: Vec<ChannelId>,
}

/// What closing an account leaves the caller to act on at once.
#[derive(Debug)]
pub struct ClosedAccount {
    /// Every session the account had, so their sockets close.
    pub revoked: Vec<SessionId>,
    /// Set when the account owned the Space and ownership passed on.
    pub handoff: Option<Handoff>,
}

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
    /// user row is tombstoned and anonymized (name and profile fields cleared)
    /// so the username frees up and login is impossible. Returns the sessions
    /// that were revoked so the caller can close their live sockets, and any
    /// ownership hand-off for it to announce.
    ///
    /// Concurrency: the account is closed first, in one short transaction whose
    /// first statement is a write, so a login racing it serializes against it
    /// (see [`Store::open_session`]). Everything it authored is then cleared in
    /// bounded steps, each its own transaction, so other writers interleave; a
    /// write that lands from an in-flight request before those steps is
    /// cleared with the rest. A restart finishes a purge that stopped part way.
    ///
    /// Every authorship column is cleared here by hand, including
    /// `reports.reporter_id` and `reports.resolved_by`. Those two carry
    /// `ON DELETE SET NULL` in `0005_safety.sql` and it never fires: deletion
    /// here is a tombstone `UPDATE`, never a `DELETE FROM users`, so the
    /// constraint has nothing to trigger on. `ReportDto.reporter_id`'s own doc
    /// comment already promised "null once the reporter's account has been
    /// anonymized", which was not true of any code path until this cleared it.
    ///
    /// Deleting the Space owner hands ownership on in the same transaction; see
    /// [`super::space_owner::hand_on_owner`].
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
    /// one person who most clearly has the right to leave. Bots and webhooks
    /// left behind are not people anyone strands.
    pub async fn delete_account(
        &self,
        user_id: UserId,
    ) -> Result<DeletedAccount, DeleteAccountError> {
        self.purge_account(user_id, None).await
    }

    /// [`Store::delete_account`] as an administrator's act on somebody else's
    /// account: the same purge, plus an `account_delete` row in the moderation
    /// audit log written in the same transaction, since nothing undoes it.
    pub async fn delete_account_by_admin(
        &self,
        user_id: UserId,
        deleted_by: UserId,
    ) -> Result<DeletedAccount, DeleteAccountError> {
        self.purge_account(user_id, Some(deleted_by)).await
    }

    async fn purge_account(
        &self,
        user_id: UserId,
        audited_by: Option<UserId>,
    ) -> Result<DeletedAccount, DeleteAccountError> {
        let closed = self.close_account(user_id, audited_by).await?;
        let cleared = self.clear_account(user_id).await;
        Ok(DeletedAccount {
            revoked: closed.revoked,
            handoff: closed.handoff,
            reactions_changed: cleared.reactions_changed,
            polls_changed: cleared.polls_changed,
            rooms_renamed: cleared.rooms_renamed,
        })
    }

    /// The first half of a deletion: the account is closed and its sessions revoked, and the
    /// bounded clean-up is left for [`Store::clear_account`], which a caller can run apart.
    pub async fn close_account_for_deletion(
        &self,
        user_id: UserId,
        audited_by: Option<UserId>,
    ) -> Result<ClosedAccount, DeleteAccountError> {
        self.close_account(user_id, audited_by).await
    }

    /// The second half of a deletion. The account is already closed, so a failed clean-up is
    /// left to the sweep rather than reported as a failed delete.
    pub async fn clear_account(&self, user_id: UserId) -> Cleared {
        match self.clear_closed_account(user_id).await {
            Ok(cleared) => cleared,
            Err(err) => {
                tracing::warn!(error = %err, "account clean-up stopped part way; the sweep will finish it");
                Cleared::default()
            }
        }
    }

    /// Finishes every purge a stopped server left part way, once it has sat for `stale_ms`.
    pub async fn finish_interrupted_account_purges(&self, stale_ms: i64) -> anyhow::Result<usize> {
        let before = now_ms() - stale_ms;
        let pending = sqlx::query_scalar!(
            r#"SELECT user_id AS "user_id!: UserId" FROM account_purges WHERE started_at <= ?"#,
            before
        )
        .fetch_all(&self.pool)
        .await?;
        for user_id in &pending {
            self.clear_closed_account(*user_id).await?;
        }
        Ok(pending.len())
    }

    /// Members whose module data has not been purged yet.
    pub async fn pending_module_data_purges(&self) -> anyhow::Result<Vec<UserId>> {
        Ok(sqlx::query_scalar!(
            r#"SELECT user_id AS "user_id!: UserId" FROM module_data_purges ORDER BY started_at"#
        )
        .fetch_all(&self.pool)
        .await?)
    }

    /// Records that every module's data about `user_id` is purged.
    pub async fn finish_module_data_purge(&self, user_id: UserId) -> anyhow::Result<()> {
        sqlx::query!("DELETE FROM module_data_purges WHERE user_id = ?", user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// The bounded clean-up after [`Self::close_account`]; idempotent, so a resumed run repeats it safely.
    async fn clear_closed_account(&self, user_id: UserId) -> anyhow::Result<bounded::Cleared> {
        let mut cleared = bounded::clear_authored_content(self, user_id).await?;
        let mut tx = self.begin_write().await?;
        cleared.rooms_renamed = anonymize::anonymize_authored_content(&mut tx, user_id).await?;
        personal::purge_personal_data(&mut tx, user_id).await?;
        sqlx::query!("DELETE FROM account_purges WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(cleared)
    }

    /// Closes the account in one short transaction: sessions and credentials
    /// gone, the user row tombstoned, ownership passed on, and the purge recorded
    /// as pending.
    async fn close_account(
        &self,
        user_id: UserId,
        audited_by: Option<UserId>,
    ) -> Result<ClosedAccount, DeleteAccountError> {
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

        // Already-revoked sessions are returned too: a quiet revoke leaves its socket open.
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

        personal::purge_credentials(&mut tx, user_id).await?;

        // The live-username index excludes tombstones, so the name frees up.
        let tombstone = format!("deleted-{user_id}");
        sqlx::query!(
            "UPDATE users
             SET deleted_at = ?, is_anonymized = 1, password_hash = NULL,
                 username = ?, display_name = 'Deleted User',
                 status_text = NULL, pronouns = NULL, about = NULL,
                 profile_color = NULL, profile_color_rgb = NULL,
                 avatar_updated_at = NULL, banner_updated_at = NULL
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
                   WHERE deleted_at IS NULL AND is_bot = 0 AND is_webhook = 0 AND id != ?"#,
                user_id
            )
            .fetch_one(&mut *tx)
            .await?;
            if others > 0 {
                return Err(DeleteAccountError::WouldStrandDeployment);
            }
        }

        let handoff = super::space_owner::hand_on_owner(&mut tx).await?.handoff;

        if let Some(actor_id) = audited_by {
            record_moderation_audit(
                &mut tx,
                ModerationAudit {
                    actor_id,
                    subject_id: user_id,
                    action: ModerationAction::AccountDelete,
                    reason: None,
                    until: None,
                    created_at: now,
                },
            )
            .await?;
        }

        sqlx::query!(
            "INSERT INTO account_purges (user_id, started_at) VALUES (?, ?)
             ON CONFLICT (user_id) DO UPDATE SET started_at = excluded.started_at",
            user_id,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO module_data_purges (user_id, started_at) VALUES (?, ?)
             ON CONFLICT (user_id) DO UPDATE SET started_at = excluded.started_at",
            user_id,
            now
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(ClosedAccount { revoked, handoff })
    }
}
