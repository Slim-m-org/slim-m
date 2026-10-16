// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Space-local display names (decision 0055): what an administrator calls
//! another member or bot, kept beside `users.display_name` rather than over it.
//!
//! The account's own name is never touched here, so renaming is always
//! reversible and the account still reads its own name in its own session.
//! Each set and clear is audited in the transaction that makes it.

use std::collections::HashMap;

use super::moderation_audit::{ModerationAction, ModerationAudit, record_moderation_audit};
use super::{MAX_IDS_PER_QUERY, Store, now_ms};
use crate::ids::UserId;

impl Store {
    /// Sets or replaces `subject`'s nickname. `Ok(None)` means the account is
    /// gone; `Ok(Some(false))` means it already had exactly this name, which
    /// writes and audits nothing.
    pub async fn set_nickname(
        &self,
        subject: UserId,
        nickname: &str,
        actor: UserId,
    ) -> anyhow::Result<Option<bool>> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let live = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM users WHERE id = ? AND deleted_at IS NULL"#,
            subject
        )
        .fetch_optional(&mut *tx)
        .await?;
        if live.is_none() {
            return Ok(None);
        }
        let current = sqlx::query_scalar!(
            "SELECT nickname FROM member_nicknames WHERE user_id = ?",
            subject
        )
        .fetch_optional(&mut *tx)
        .await?;
        if current.as_deref() == Some(nickname) {
            return Ok(Some(false));
        }
        sqlx::query!(
            "INSERT INTO member_nicknames (user_id, nickname, set_by, set_at)
             VALUES (?, ?, ?, ?)
             ON CONFLICT(user_id) DO UPDATE SET
                 nickname = excluded.nickname,
                 set_by = excluded.set_by,
                 set_at = excluded.set_at",
            subject,
            nickname,
            actor,
            now
        )
        .execute(&mut *tx)
        .await?;
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: actor,
                subject_id: subject,
                action: ModerationAction::NicknameSet,
                reason: Some(nickname),
                until: None,
                created_at: now,
            },
        )
        .await?;
        tx.commit().await?;
        Ok(Some(true))
    }

    /// Removes `subject`'s nickname. Idempotent: answers whether one was there.
    pub async fn clear_nickname(&self, subject: UserId, actor: UserId) -> anyhow::Result<bool> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let removed = sqlx::query!("DELETE FROM member_nicknames WHERE user_id = ?", subject)
            .execute(&mut *tx)
            .await?
            .rows_affected()
            > 0;
        if removed {
            record_moderation_audit(
                &mut tx,
                ModerationAudit {
                    actor_id: actor,
                    subject_id: subject,
                    action: ModerationAction::NicknameClear,
                    reason: None,
                    until: None,
                    created_at: now,
                },
            )
            .await?;
        }
        tx.commit().await?;
        Ok(removed)
    }

    /// The nicknames in force among `ids`; an id with none is simply absent.
    pub async fn nicknames_for(&self, ids: &[UserId]) -> anyhow::Result<HashMap<UserId, String>> {
        use sqlx::Row;

        let mut out = HashMap::new();
        for chunk in ids.chunks(MAX_IDS_PER_QUERY) {
            let mut builder = sqlx::QueryBuilder::new(
                "SELECT user_id, nickname FROM member_nicknames WHERE user_id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                out.insert(row.try_get("user_id")?, row.try_get("nickname")?);
            }
        }
        Ok(out)
    }
}
