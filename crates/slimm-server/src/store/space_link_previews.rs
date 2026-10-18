// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space's own choice about link previews, over the operator's default.

use anyhow::Context;

use super::{Store, now_ms};

impl Store {
    /// The admin's choice, or None while the operator's default stands.
    pub async fn link_previews_override(&self) -> anyhow::Result<Option<bool>> {
        let value = sqlx::query_scalar!(
            r#"SELECT link_previews AS "v: bool" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read link previews override")?;
        Ok(value.flatten())
    }

    pub async fn set_link_previews_override(&self, enabled: bool) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET link_previews = ?, updated_at = ? WHERE id = 1",
            enabled,
            now
        )
        .execute(&self.pool)
        .await
        .context("set link previews override")?;
        Ok(())
    }
}
