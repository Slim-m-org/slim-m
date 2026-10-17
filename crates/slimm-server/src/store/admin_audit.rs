// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `admin_audit_log`: one row per admin change to the space, written by the
//! HTTP middleware in `http/admin_audit.rs` and read back newest first.

use super::{Store, now_ms};
use crate::ids::UserId;

/// One admin change as stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminAuditEntry {
    pub id: i64,
    /// Null once the actor's account is gone.
    pub actor_id: Option<UserId>,
    pub action: String,
    pub target_id: Option<String>,
    /// A JSON object; see migration 0121 for what it may hold.
    pub detail: String,
    pub created_at: i64,
}

impl Store {
    pub async fn record_admin_change(
        &self,
        actor_id: UserId,
        action: &str,
        target_id: Option<&str>,
        detail: &str,
    ) -> anyhow::Result<()> {
        let created_at = now_ms();
        sqlx::query!(
            "INSERT INTO admin_audit_log (actor_id, action, target_id, detail, created_at)
             VALUES (?, ?, ?, ?, ?)",
            actor_id,
            action,
            target_id,
            detail,
            created_at
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Up to `limit` changes older than `before` (an entry id), newest first.
    pub async fn admin_changes(
        &self,
        before: Option<i64>,
        limit: i64,
    ) -> anyhow::Result<Vec<AdminAuditEntry>> {
        let before = before.unwrap_or(i64::MAX);
        let rows = sqlx::query_as!(
            AdminAuditEntry,
            r#"SELECT id AS "id!", actor_id AS "actor_id: UserId", action, target_id,
                      detail, created_at
               FROM admin_audit_log WHERE id < ? ORDER BY id DESC LIMIT ?"#,
            before,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }
}
