// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space theme store and its default (decision 0106).

use anyhow::Context;
use sqlx::Row;

use super::{Store, now_ms};
use crate::ids::{ThemeId, UserId};
use crate::space_theme::{MAX_AUTHOR_THEMES, MAX_STORE_THEMES};

#[derive(Debug, Clone)]
pub struct SpaceTheme {
    pub id: ThemeId,
    pub name: String,
    pub author_id: Option<UserId>,
    pub author_name: String,
    pub doc: String,
    pub has_picture: bool,
    pub created_at: i64,
}

/// A picture and the content type it was sniffed as.
pub struct ThemePicture {
    pub bytes: Vec<u8>,
    pub content_type: String,
}

/// Why a publish was refused.
#[derive(Debug, PartialEq, Eq)]
pub enum PublishError {
    Full,
    AuthorFull,
}

impl Store {
    pub async fn list_space_themes(&self) -> anyhow::Result<Vec<SpaceTheme>> {
        let rows = sqlx::query(
            "SELECT id, name, author_id, author_name, doc, picture IS NOT NULL AS has_picture,
                    created_at
             FROM space_themes ORDER BY created_at ASC, rowid ASC",
        )
        .fetch_all(&self.pool)
        .await
        .context("list space themes")?;
        rows.iter().map(theme_of).collect()
    }

    pub async fn space_theme(&self, id: ThemeId) -> anyhow::Result<Option<SpaceTheme>> {
        let row = sqlx::query(
            "SELECT id, name, author_id, author_name, doc, picture IS NOT NULL AS has_picture,
                    created_at
             FROM space_themes WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .context("read a space theme")?;
        row.as_ref().map(theme_of).transpose()
    }

    pub async fn space_theme_picture(&self, id: ThemeId) -> anyhow::Result<Option<ThemePicture>> {
        let row = sqlx::query(
            "SELECT picture, picture_type FROM space_themes
             WHERE id = ? AND picture IS NOT NULL",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .context("read a theme picture")?;
        Ok(row.map(|row| ThemePicture {
            bytes: row.get("picture"),
            content_type: row.get("picture_type"),
        }))
    }

    /// Adds a theme unless the Space is at [`MAX_STORE_THEMES`] or the author at
    /// [`MAX_AUTHOR_THEMES`]; the counts and the insert share one write
    /// transaction so two publishes cannot both pass.
    pub async fn publish_space_theme(
        &self,
        author: UserId,
        author_name: &str,
        name: &str,
        doc: &str,
        picture: Option<(&[u8], &str)>,
    ) -> anyhow::Result<Result<SpaceTheme, PublishError>> {
        let mut tx = self.begin_write().await?;
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM space_themes")
            .fetch_one(&mut *tx)
            .await?;
        if count >= MAX_STORE_THEMES {
            return Ok(Err(PublishError::Full));
        }
        let own: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM space_themes WHERE author_id = ?")
            .bind(author)
            .fetch_one(&mut *tx)
            .await?;
        if own >= MAX_AUTHOR_THEMES {
            return Ok(Err(PublishError::AuthorFull));
        }
        let id = ThemeId::generate();
        let now = now_ms();
        sqlx::query(
            "INSERT INTO space_themes
                 (id, name, author_id, author_name, doc, picture, picture_type, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(name)
        .bind(author)
        .bind(author_name)
        .bind(doc)
        .bind(picture.map(|(bytes, _)| bytes))
        .bind(picture.map(|(_, content_type)| content_type))
        .bind(now)
        .execute(&mut *tx)
        .await
        .context("publish a space theme")?;
        tx.commit().await?;
        let theme = self
            .space_theme(id)
            .await?
            .context("published theme vanished")?;
        Ok(Ok(theme))
    }

    /// False when there was no such theme. Clears the default when it was the default.
    pub async fn delete_space_theme(&self, id: ThemeId) -> anyhow::Result<bool> {
        let mut tx = self.begin_write().await?;
        sqlx::query(
            "UPDATE space_settings SET default_theme_id = NULL, updated_at = ?
             WHERE default_theme_id = ?",
        )
        .bind(now_ms())
        .bind(id)
        .execute(&mut *tx)
        .await?;
        let gone = sqlx::query("DELETE FROM space_themes WHERE id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        tx.commit().await?;
        Ok(gone > 0)
    }

    pub async fn default_space_theme(&self) -> anyhow::Result<Option<ThemeId>> {
        let row = sqlx::query("SELECT default_theme_id FROM space_settings WHERE id = 1")
            .fetch_optional(&self.pool)
            .await
            .context("read the default theme")?;
        Ok(row.and_then(|row| row.get::<Option<ThemeId>, _>("default_theme_id")))
    }

    pub async fn set_default_space_theme(&self, id: Option<ThemeId>) -> anyhow::Result<()> {
        sqlx::query("UPDATE space_settings SET default_theme_id = ?, updated_at = ? WHERE id = 1")
            .bind(id)
            .bind(now_ms())
            .execute(&self.pool)
            .await
            .context("set the default theme")?;
        Ok(())
    }
}

fn theme_of(row: &sqlx::sqlite::SqliteRow) -> anyhow::Result<SpaceTheme> {
    Ok(SpaceTheme {
        id: row.try_get("id")?,
        name: row.try_get("name")?,
        author_id: row.try_get("author_id")?,
        author_name: row.try_get("author_name")?,
        doc: row.try_get("doc")?,
        has_picture: row.try_get("has_picture")?,
        created_at: row.try_get("created_at")?,
    })
}
