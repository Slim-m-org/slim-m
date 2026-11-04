// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The account's hold-music choice, shared by all of a member's devices.

use super::Store;
use crate::ids::UserId;

impl Store {
    /// The member's choice, `Some(None)` if never made. `None` if the account is gone.
    pub async fn hold_music(&self, user_id: UserId) -> anyhow::Result<Option<Option<bool>>> {
        let row: Option<Option<i64>> = sqlx::query_scalar(
            "SELECT hold_music_enabled FROM users WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|choice| choice.map(|v| v != 0)))
    }

    /// Saves the choice. Returns `false` if the account is gone.
    pub async fn set_hold_music(&self, user_id: UserId, enabled: bool) -> anyhow::Result<bool> {
        let affected = sqlx::query(
            "UPDATE users SET hold_music_enabled = ? WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(enabled)
        .bind(user_id)
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }
}
