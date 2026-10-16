// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Member timeouts: a moderator takes away every way of expressing yourself
//! for a while, and takes away nothing else.
//!
//! The enforcement is one subtraction applied where permissions are read, not
//! a check bolted onto each thing a timed-out member must not do. That is the
//! same shape [`super::dms`]'s `BLOCKED_DENY` uses, and it is what makes this
//! reach message send, edits, reactions, attachments, polls, pins and the
//! LiveKit token with no edit to any of those files: they all already ask
//! [`Store::permissions_in_channel`], and the voice token even degrades to
//! listen-only on its own because `VoiceService::mint` derives `can_publish`
//! from [`Permissions::SPEAK`].
//!
//! `until` is compared against the clock at every read rather than swept by a
//! job, so a timeout expires by arithmetic. Nothing has to run on time for a
//! member to get their voice back, which is the property worth having.

use std::collections::HashMap;

use super::moderation_audit::{ModerationAction, ModerationAudit, record_moderation_audit};
use super::{Store, now_ms};
use crate::ids::UserId;
use crate::permissions::Permissions;

/// The longest timeout that can be issued, matching the ceiling the shape of
/// this feature implies: past about a month, the honest tool is a removal.
pub const MAX_TIMEOUT_MS: i64 = 28 * 24 * 60 * 60 * 1000;

/// What a timeout takes away: everything that puts something into the Space,
/// plus the two voice bits.
///
/// `VIEW_CHANNEL` survives, so a timed-out member reads the conversation they
/// are being kept out of - that is the entire difference between this and a
/// removal, and it is why the client copy says "can read, can't post".
///
/// `USE_CANVAS` is deliberately absent even though drawing is plainly a way
/// of posting: that one bit means "view *and* draw the canvas" (see its
/// definition in `permissions.rs`), so subtracting it would blank the canvas
/// rather than make it read-only. The canvas write path checks the timeout
/// directly instead; splitting the bit is a schema and role migration that
/// belongs to the Phase 6 canvas work rather than to this.
pub(crate) const TIMEOUT_DENY: Permissions = Permissions::SEND_MESSAGES
    .union(Permissions::ADD_REACTIONS)
    .union(Permissions::ATTACH_FILES)
    .union(Permissions::CONNECT)
    .union(Permissions::SPEAK);

/// Why a timeout was refused.
#[derive(Debug)]
pub enum TimeoutError {
    /// The account does not exist, or has been deleted.
    UserNotFound,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for TimeoutError {
    fn from(err: sqlx::Error) -> Self {
        TimeoutError::Internal(err.into())
    }
}

/// A timeout in force, as a moderator sees it.
#[derive(Debug, Clone)]
pub struct MemberTimeout {
    pub user_id: UserId,
    pub until: i64,
    pub reason: Option<String>,
    /// Null once the issuing moderator's own account is deleted.
    pub issued_by: Option<UserId>,
    pub issued_at: i64,
}

impl Store {
    /// Applies a timeout, replacing any timeout already on this member.
    /// Answers whether anything changed: the same deadline and reason again
    /// writes and audits nothing.
    ///
    /// Replacing rather than refusing is what lets a moderator shorten one
    /// they overdid, and re-issuing is the only thing "extend it" could mean.
    ///
    /// The replaced row is gone afterwards, so each issue is also appended to
    /// `moderation_audit_log` in the same transaction; that log is the only
    /// place a moderator can see that this is the third one this month.
    pub async fn set_member_timeout(
        &self,
        user_id: UserId,
        until: i64,
        reason: Option<&str>,
        issued_by: UserId,
    ) -> Result<bool, TimeoutError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let changed = timeout_one(&mut tx, user_id, until, reason, issued_by, now).await?;
        tx.commit().await?;
        Ok(changed)
    }

    /// Lifts a timeout. Idempotent: lifting one that already expired, or one
    /// that never existed, is a success rather than an error, because in both
    /// cases the member can speak afterwards, which is what the caller asked.
    ///
    /// Only a lift that found a row is audited, and it carries the deadline it
    /// cut short: an idempotent second call changed nothing, so recording it
    /// would put an act in the trail that never happened. An elapsed row still
    /// counts, since deleting it is a real edit even though nobody was silent
    /// by then.
    pub async fn clear_member_timeout(
        &self,
        user_id: UserId,
        cleared_by: UserId,
    ) -> anyhow::Result<bool> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let lifted = sqlx::query_scalar!(
            "SELECT until FROM member_timeouts WHERE user_id = ?",
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(until) = lifted {
            sqlx::query!("DELETE FROM member_timeouts WHERE user_id = ?", user_id)
                .execute(&mut *tx)
                .await?;
            record_moderation_audit(
                &mut tx,
                ModerationAudit {
                    actor_id: cleared_by,
                    subject_id: user_id,
                    action: ModerationAction::TimeoutCleared,
                    reason: None,
                    until: Some(until),
                    created_at: now,
                },
            )
            .await?;
        }

        tx.commit().await?;
        Ok(lifted.is_some())
    }

    /// The timeout in force on this member right now, if any. An elapsed row
    /// answers `None`, since the row outliving its own deadline is normal.
    pub async fn member_timeout(&self, user_id: UserId) -> anyhow::Result<Option<MemberTimeout>> {
        let now = now_ms();
        let row = sqlx::query!(
            r#"SELECT until, reason, issued_by AS "issued_by?: UserId", issued_at
               FROM member_timeouts WHERE user_id = ? AND until > ?"#,
            user_id,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| MemberTimeout {
            user_id,
            until: r.until,
            reason: r.reason,
            issued_by: r.issued_by,
            issued_at: r.issued_at,
        }))
    }

    /// When this member's timeout lifts, or `None` if they are not timed out.
    /// The cheap read the profile and member-list responses carry.
    pub async fn timed_out_until(&self, user_id: UserId) -> anyhow::Result<Option<i64>> {
        let now = now_ms();
        let row = sqlx::query_scalar!(
            "SELECT until FROM member_timeouts WHERE user_id = ? AND until > ?",
            user_id,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    /// What to subtract from this member's permissions, everywhere.
    pub(super) async fn timeout_deny(&self, user_id: UserId) -> anyhow::Result<Permissions> {
        Ok(match self.timed_out_until(user_id).await? {
            Some(_) => TIMEOUT_DENY,
            None => Permissions::NONE,
        })
    }

    /// Which of `candidates` are timed out and until when, in one query.
    ///
    /// Batched for the same reason the role lookups beside it are: push
    /// fan-out and the member list both ask about many people at once, and a
    /// per-candidate query would restore exactly the N+1 those paths exist to
    /// remove. Absent from the map means not timed out.
    pub async fn timed_out_among_until(
        &self,
        candidates: &[UserId],
    ) -> anyhow::Result<HashMap<UserId, i64>> {
        if candidates.is_empty() {
            return Ok(HashMap::new());
        }
        let now = now_ms();
        // Built, not `query!`: the id list is variable and SQLite has no arrays.
        let mut builder =
            sqlx::QueryBuilder::new("SELECT user_id, until FROM member_timeouts WHERE until > ");
        builder.push_bind(now);
        builder.push(" AND user_id IN (");
        let mut separated = builder.separated(", ");
        for id in candidates {
            separated.push_bind(*id);
        }
        builder.push(")");

        use sqlx::Row;
        let rows = builder.build().fetch_all(&self.pool).await?;
        let mut out = HashMap::new();
        for row in rows {
            out.insert(row.try_get("user_id")?, row.try_get("until")?);
        }
        Ok(out)
    }
}

/// One timeout, inside a transaction the caller owns.
///
/// Split out for the reason [`super::removals::remove_one`] gives: the bulk
/// path runs this rather than a second copy, so the replace-not-refuse rule
/// and the audit row cannot drift apart between the two verbs.
pub(super) async fn timeout_one(
    tx: &mut sqlx::SqliteConnection,
    user_id: UserId,
    until: i64,
    reason: Option<&str>,
    issued_by: UserId,
    now: i64,
) -> Result<bool, TimeoutError> {
    let exists = sqlx::query_scalar!(
        r#"SELECT 1 AS "one!: i64" FROM users WHERE id = ? AND deleted_at IS NULL"#,
        user_id
    )
    .fetch_optional(&mut *tx)
    .await?;
    if exists.is_none() {
        return Err(TimeoutError::UserNotFound);
    }
    let current = sqlx::query!(
        "SELECT until, reason FROM member_timeouts WHERE user_id = ?",
        user_id
    )
    .fetch_optional(&mut *tx)
    .await?;
    if current.is_some_and(|row| row.until == until && row.reason.as_deref() == reason) {
        return Ok(false);
    }
    sqlx::query!(
        "INSERT INTO member_timeouts (user_id, until, reason, issued_by, issued_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(user_id) DO UPDATE SET
             until = excluded.until,
             reason = excluded.reason,
             issued_by = excluded.issued_by,
             issued_at = excluded.issued_at",
        user_id,
        until,
        reason,
        issued_by,
        now
    )
    .execute(&mut *tx)
    .await?;

    record_moderation_audit(
        tx,
        ModerationAudit {
            actor_id: issued_by,
            subject_id: user_id,
            action: ModerationAction::Timeout,
            reason,
            until: Some(until),
            created_at: now,
        },
    )
    .await?;
    Ok(true)
}
