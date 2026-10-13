// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The public face of the deployment: the banner and description an invite
//! link's landing card shows before anyone has an account.

use anyhow::Context;

use super::Store;
use super::now_ms;

/// Longest description, in characters. Enforced in Rust so it can move
/// without a migration.
pub const MAX_SPACE_DESCRIPTION_CHARS: usize = 280;

/// What the landing card shows besides the name and head count.
#[derive(Debug, Clone, Default)]
pub struct SpaceLanding {
    pub description: String,
    /// When the banner was last set; `None` means no banner.
    pub banner_updated_at: Option<i64>,
    /// When the icon was last set; `None` means no icon.
    pub icon_updated_at: Option<i64>,
}

impl Store {
    pub async fn space_landing(&self) -> anyhow::Result<SpaceLanding> {
        let row = sqlx::query!(
            r#"SELECT description AS "description!: String", banner_updated_at, icon_updated_at
               FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read space landing")?;
        Ok(row
            .map(|r| SpaceLanding {
                description: r.description,
                banner_updated_at: r.banner_updated_at,
                icon_updated_at: r.icon_updated_at,
            })
            .unwrap_or_default())
    }

    pub async fn set_space_description(&self, description: &str) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET description = ?, updated_at = ? WHERE id = 1",
            description,
            now
        )
        .execute(&self.pool)
        .await
        .context("set space description")?;
        Ok(())
    }

    /// `Some(now)` records a new banner, `None` clears it.
    pub async fn set_space_banner(&self, updated_at: Option<i64>) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET banner_updated_at = ?, updated_at = ? WHERE id = 1",
            updated_at,
            now
        )
        .execute(&self.pool)
        .await
        .context("set space banner")?;
        Ok(())
    }

    /// `Some(now)` records a new icon, `None` clears it.
    pub async fn set_space_icon(&self, updated_at: Option<i64>) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET icon_updated_at = ?, updated_at = ? WHERE id = 1",
            updated_at,
            now
        )
        .execute(&self.pool)
        .await
        .context("set space icon")?;
        Ok(())
    }
}
