// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space's upload compression settings: whether photos are shrunk, which
//! file types, what happens to their metadata, and whether the original stays.

use anyhow::Context;

use super::{Store, now_ms};
use crate::media::compress::{DEFAULT_EXTENSIONS, Metadata};

/// The settings as stored; `extensions` is the effective list, defaults filled in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaCompression {
    pub enabled: bool,
    pub extensions: Vec<String>,
    pub metadata: Metadata,
    pub keep_original: bool,
}

/// A change to the settings; a `None` field stays as it is.
#[derive(Debug, Default)]
pub struct MediaCompressionUpdate {
    pub enabled: Option<bool>,
    /// Normalized extensions; an empty list restores the defaults.
    pub extensions: Option<Vec<String>>,
    pub metadata: Option<Metadata>,
    pub keep_original: Option<bool>,
}

impl Store {
    pub async fn media_compression(&self) -> anyhow::Result<MediaCompression> {
        let row = sqlx::query!(
            r#"SELECT media_compress AS "enabled!: bool", media_compress_types AS "types!",
                      media_metadata AS "metadata!", media_keep_original AS "keep!: bool"
               FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read media compression")?;
        let Some(row) = row else {
            return Ok(MediaCompression::off());
        };
        let listed: Vec<String> = row
            .types
            .split(',')
            .filter(|ext| !ext.is_empty())
            .map(str::to_owned)
            .collect();
        Ok(MediaCompression {
            enabled: row.enabled,
            extensions: if listed.is_empty() {
                default_extensions()
            } else {
                listed
            },
            metadata: Metadata::parse(&row.metadata).unwrap_or(Metadata::RemoveLocation),
            keep_original: row.keep,
        })
    }

    pub async fn update_media_compression(
        &self,
        update: MediaCompressionUpdate,
    ) -> anyhow::Result<MediaCompression> {
        let mut tx = self.begin_write().await?;
        let now = now_ms();
        if let Some(enabled) = update.enabled {
            sqlx::query!(
                "UPDATE space_settings SET media_compress = ?, updated_at = ? WHERE id = 1",
                enabled,
                now
            )
            .execute(&mut *tx)
            .await?;
        }
        if let Some(extensions) = &update.extensions {
            let joined = extensions.join(",");
            sqlx::query!(
                "UPDATE space_settings SET media_compress_types = ?, updated_at = ? WHERE id = 1",
                joined,
                now
            )
            .execute(&mut *tx)
            .await?;
        }
        if let Some(metadata) = update.metadata {
            let mode = metadata.as_str();
            sqlx::query!(
                "UPDATE space_settings SET media_metadata = ?, updated_at = ? WHERE id = 1",
                mode,
                now
            )
            .execute(&mut *tx)
            .await?;
        }
        if let Some(keep) = update.keep_original {
            sqlx::query!(
                "UPDATE space_settings SET media_keep_original = ?, updated_at = ? WHERE id = 1",
                keep,
                now
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        self.media_compression().await
    }
}

impl MediaCompression {
    fn off() -> Self {
        Self {
            enabled: false,
            extensions: default_extensions(),
            metadata: Metadata::RemoveLocation,
            keep_original: false,
        }
    }
}

pub fn default_extensions() -> Vec<String> {
    DEFAULT_EXTENSIONS.iter().map(|e| (*e).to_owned()).collect()
}
