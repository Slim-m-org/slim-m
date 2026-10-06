// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for the legacy account-wide quiet-hours window (migration
//! 0056): an optional time-of-day span, in minutes since midnight UTC.
//!
//! Read and written only by `GET`/`PUT /push/quiet-hours`. Push fan-out reads
//! the notification schedule instead (decision 0033), so nothing here
//! narrows a recipient.

use super::Store;
use crate::ids::UserId;
use crate::notifications::QuietHours;

impl Store {
    /// The caller's own quiet-hours window, or `None` when disabled or the
    /// account is gone - the two collapse here because every caller of this
    /// function has already confirmed the account exists through a sibling
    /// read in the same request (`GET /push/quiet-hours` reads
    /// [`Store::notification_preference`] first), so a second "does this
    /// account exist" answer is not needed.
    pub async fn quiet_hours(&self, user_id: UserId) -> anyhow::Result<Option<QuietHours>> {
        let row = sqlx::query!(
            r#"SELECT quiet_hours_start_minute AS "start: i64", quiet_hours_end_minute AS "end: i64"
               FROM users WHERE id = ? AND deleted_at IS NULL"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.and_then(|r| match (r.start, r.end) {
            (Some(start), Some(end)) => QuietHours::parse(start, end),
            _ => None,
        }))
    }

    /// Sets or clears the caller's quiet-hours window. Returns `false` if
    /// the account is gone, the same tiny concurrent-deletion window
    /// documented on [`Store::update_profile`](super::Store::update_profile).
    pub async fn set_quiet_hours(
        &self,
        user_id: UserId,
        quiet_hours: Option<QuietHours>,
    ) -> anyhow::Result<bool> {
        let (start, end) = match quiet_hours {
            Some(window) => (
                Some(i64::from(window.start_minute)),
                Some(i64::from(window.end_minute)),
            ),
            None => (None, None),
        };
        let affected = sqlx::query!(
            "UPDATE users SET quiet_hours_start_minute = ?, quiet_hours_end_minute = ?
             WHERE id = ? AND deleted_at IS NULL",
            start,
            end,
            user_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }
}
