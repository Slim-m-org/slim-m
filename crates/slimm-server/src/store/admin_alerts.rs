// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Storage for operator alerts: the open conditions, the push rate limit that
//! reads `notified_at`, and the audience of unmuted `MANAGE_SERVER` holders.
//! The policy lives in `crate::admin_alerts`.

use anyhow::Context;

use super::Store;
use crate::ids::UserId;
use crate::permissions::Permissions;

/// One condition, open or recently recovered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminAlert {
    pub kind: String,
    pub subject: String,
    pub detail: String,
    pub raised_at: i64,
    pub resolved_at: Option<i64>,
}

/// A condition [`Store::resolve_admin_alert`] closed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedAlert {
    pub alert: AdminAlert,
    /// Whether a push had gone out when it opened, which earns a recovery push.
    pub notified: bool,
}

/// What [`Store::raise_admin_alert`] found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Raised {
    /// The condition just opened, or reopened after recovering.
    Opened,
    /// It was already open.
    AlreadyOpen,
}

impl Store {
    /// Opens the condition, or refreshes its detail when it is already open.
    pub async fn raise_admin_alert(
        &self,
        kind: &str,
        subject: &str,
        detail: &str,
        now: i64,
    ) -> anyhow::Result<Raised> {
        let mut tx = self.begin_write().await?;
        let open = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "open!: i64" FROM admin_alerts
               WHERE kind = ? AND subject = ? AND resolved_at IS NULL"#,
            kind,
            subject
        )
        .fetch_one(&mut *tx)
        .await
        .context("read admin alert")?;
        sqlx::query!(
            "INSERT INTO admin_alerts (kind, subject, detail, raised_at) VALUES (?, ?, ?, ?)
             ON CONFLICT (kind, subject) DO UPDATE SET
                 detail = excluded.detail,
                 raised_at = CASE WHEN admin_alerts.resolved_at IS NULL
                                  THEN admin_alerts.raised_at ELSE excluded.raised_at END,
                 announced = CASE WHEN admin_alerts.resolved_at IS NULL
                                  THEN admin_alerts.announced ELSE 0 END,
                 resolved_at = NULL",
            kind,
            subject,
            detail,
            now
        )
        .execute(&mut *tx)
        .await
        .context("raise admin alert")?;
        tx.commit().await?;
        Ok(if open > 0 {
            Raised::AlreadyOpen
        } else {
            Raised::Opened
        })
    }

    /// Claims the right to push for this condition: false when any alert of the
    /// same kind was pushed inside `window_ms`, so a flapping condition stays quiet.
    pub async fn claim_admin_alert_push(
        &self,
        kind: &str,
        subject: &str,
        now: i64,
        window_ms: i64,
    ) -> anyhow::Result<bool> {
        let floor = now - window_ms;
        let claimed = sqlx::query!(
            "UPDATE admin_alerts SET notified_at = ?, announced = 1
             WHERE kind = ? AND subject = ?
               AND NOT EXISTS (SELECT 1 FROM admin_alerts WHERE kind = ? AND notified_at > ?)",
            now,
            kind,
            subject,
            kind,
            floor
        )
        .execute(&self.pool)
        .await
        .context("claim admin alert push")?
        .rows_affected();
        Ok(claimed == 1)
    }

    /// Closes the condition. `None` when it was not open.
    pub async fn resolve_admin_alert(
        &self,
        kind: &str,
        subject: &str,
        now: i64,
    ) -> anyhow::Result<Option<ResolvedAlert>> {
        let row = sqlx::query!(
            "UPDATE admin_alerts SET resolved_at = ?
             WHERE kind = ? AND subject = ? AND resolved_at IS NULL
             RETURNING detail, raised_at, announced AS \"announced: bool\"",
            now,
            kind,
            subject
        )
        .fetch_optional(&self.pool)
        .await
        .context("resolve admin alert")?;
        Ok(row.map(|row| ResolvedAlert {
            notified: row.announced,
            alert: AdminAlert {
                kind: kind.to_owned(),
                subject: subject.to_owned(),
                detail: row.detail,
                raised_at: row.raised_at,
                resolved_at: Some(now),
            },
        }))
    }

    /// Open alerts plus those that recovered since `recovered_since`, newest first.
    pub async fn list_admin_alerts(&self, recovered_since: i64) -> anyhow::Result<Vec<AdminAlert>> {
        let rows = sqlx::query!(
            r#"SELECT kind, subject, detail, raised_at, resolved_at
               FROM admin_alerts
               WHERE resolved_at IS NULL OR resolved_at >= ?
               ORDER BY raised_at DESC"#,
            recovered_since
        )
        .fetch_all(&self.pool)
        .await
        .context("list admin alerts")?;
        Ok(rows
            .into_iter()
            .map(|row| AdminAlert {
                kind: row.kind,
                subject: row.subject,
                detail: row.detail,
                raised_at: row.raised_at,
                resolved_at: row.resolved_at,
            })
            .collect())
    }

    /// The subjects of open alerts of one kind.
    pub async fn open_admin_alert_subjects(&self, kind: &str) -> anyhow::Result<Vec<String>> {
        sqlx::query_scalar!(
            r#"SELECT subject AS "subject!" FROM admin_alerts
               WHERE kind = ? AND resolved_at IS NULL"#,
            kind
        )
        .fetch_all(&self.pool)
        .await
        .context("list open admin alert subjects")
    }

    /// Whether this account asked not to be told about operator alerts.
    pub async fn admin_alerts_muted(&self, user_id: UserId) -> anyhow::Result<bool> {
        let muted = sqlx::query_scalar!(
            r#"SELECT admin_alerts_muted AS "muted!: bool" FROM users WHERE id = ?"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await
        .context("read admin alert mute")?;
        Ok(muted.unwrap_or(false))
    }

    /// Sets the mute; the same value twice changes nothing.
    pub async fn set_admin_alerts_muted(&self, user_id: UserId, muted: bool) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE users SET admin_alerts_muted = ? WHERE id = ?",
            muted,
            user_id
        )
        .execute(&self.pool)
        .await
        .context("write admin alert mute")?;
        Ok(())
    }

    /// Unmuted accounts that hold `MANAGE_SERVER`, the audience of an alert.
    pub async fn admin_alert_recipients(&self) -> anyhow::Result<Vec<UserId>> {
        let mask = Permissions::ADMINISTRATOR.bits() | Permissions::MANAGE_SERVER.bits();
        let candidates: Vec<UserId> = sqlx::query_scalar!(
            r#"SELECT u.id AS "id!: UserId" FROM users u
               WHERE u.deleted_at IS NULL AND u.is_webhook = 0 AND u.admin_alerts_muted = 0
               AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id) AND (
                   EXISTS (SELECT 1 FROM roles WHERE is_everyone = 1 AND (permissions & ?) != 0)
                   OR EXISTS (
                       SELECT 1 FROM member_roles mr JOIN roles r ON r.id = mr.role_id
                       WHERE mr.user_id = u.id AND (r.permissions & ?) != 0
                   )
               )"#,
            mask,
            mask
        )
        .fetch_all(&self.pool)
        .await
        .context("list admin alert recipients")?;
        let mut holders = Vec::with_capacity(candidates.len());
        for user_id in candidates {
            if self
                .base_permissions(user_id)
                .await?
                .contains(Permissions::MANAGE_SERVER)
            {
                holders.push(user_id);
            }
        }
        Ok(holders)
    }
}
