// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How much the server logs, as the space's admins last set it (decision 0129).

use anyhow::Context;

use super::{Store, now_ms};
use crate::logging::LogMode;

impl Store {
    pub async fn log_mode(&self) -> anyhow::Result<LogMode> {
        let value = sqlx::query_scalar!("SELECT log_mode FROM space_settings WHERE id = 1")
            .fetch_optional(&self.pool)
            .await
            .context("read log mode")?;
        Ok(value
            .as_deref()
            .and_then(LogMode::parse)
            .unwrap_or_default())
    }

    pub async fn set_log_mode(&self, mode: LogMode) -> anyhow::Result<()> {
        let now = now_ms();
        let mode = mode.as_str();
        sqlx::query!(
            "UPDATE space_settings SET log_mode = ?, updated_at = ? WHERE id = 1",
            mode,
            now
        )
        .execute(&self.pool)
        .await
        .context("set log mode")?;
        Ok(())
    }
}
