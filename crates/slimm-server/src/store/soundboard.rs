// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Soundboard persistence: the Space's named audio clips.
//!
//! Shaped like `store/emoji.rs`: the bytes are an `attachments` row by sha256,
//! and this table adds the name, the validated duration and the cap.

use super::{Store, now_ms};
use crate::ids::{SoundClipId, UserId};
use crate::media::to_hex;

/// Most clips one Space may hold. Every client lists all of them to fill the picker.
pub const MAX_SOUNDBOARD_CLIPS: i64 = 48;

/// One clip as a client needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SoundClip {
    pub id: String,
    pub name: String,
    pub sha256: String,
    pub duration_ms: i64,
    /// Null once the uploader's account has been deleted.
    pub uploader_id: Option<String>,
    pub created_at: i64,
}

/// Why a write was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SoundClipError {
    /// Another clip already answers to this name.
    NameTaken,
    /// The Space is at [`MAX_SOUNDBOARD_CLIPS`].
    Full,
}

impl Store {
    /// Every clip, oldest first. Unpaginated: the set is capped.
    pub async fn list_sound_clips(&self) -> anyhow::Result<Vec<SoundClip>> {
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: SoundClipId", name AS "name!", sha256 AS "sha256!",
                      duration_ms AS "duration_ms!", uploader_id AS "uploader_id?: UserId",
                      created_at AS "created_at!"
               FROM soundboard_clips
               ORDER BY created_at ASC, rowid ASC"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| SoundClip {
                id: row.id.to_string(),
                name: row.name,
                sha256: to_hex(&row.sha256),
                duration_ms: row.duration_ms,
                uploader_id: row.uploader_id.map(|id| id.to_string()),
                created_at: row.created_at,
            })
            .collect())
    }

    /// Why adding a clip named `name` would be refused right now. Advisory:
    /// [`Store::create_sound_clip`] asks again inside its write transaction.
    pub async fn sound_clip_refusal(&self, name: &str) -> anyhow::Result<Option<SoundClipError>> {
        let count = sqlx::query_scalar!("SELECT COUNT(*) FROM soundboard_clips")
            .fetch_one(&self.pool)
            .await?;
        if count >= MAX_SOUNDBOARD_CLIPS {
            return Ok(Some(SoundClipError::Full));
        }
        let taken =
            sqlx::query_scalar!("SELECT COUNT(*) FROM soundboard_clips WHERE name = ?", name)
                .fetch_one(&self.pool)
                .await?;
        Ok((taken > 0).then_some(SoundClipError::NameTaken))
    }

    /// Records a clip against already-written bytes, counted inside the write
    /// transaction so two concurrent uploads cannot both pass the cap.
    pub async fn create_sound_clip(
        &self,
        id: SoundClipId,
        name: &str,
        sha256: &[u8],
        duration_ms: i64,
        uploader: UserId,
    ) -> anyhow::Result<Result<SoundClip, SoundClipError>> {
        let mut tx = self.begin_write().await?;
        let now = now_ms();
        let count = sqlx::query_scalar!("SELECT COUNT(*) FROM soundboard_clips")
            .fetch_one(&mut *tx)
            .await?;
        if count >= MAX_SOUNDBOARD_CLIPS {
            return Ok(Err(SoundClipError::Full));
        }
        let taken =
            sqlx::query_scalar!("SELECT COUNT(*) FROM soundboard_clips WHERE name = ?", name)
                .fetch_one(&mut *tx)
                .await?;
        if taken > 0 {
            return Ok(Err(SoundClipError::NameTaken));
        }
        sqlx::query!(
            "INSERT INTO soundboard_clips (id, name, sha256, duration_ms, uploader_id, created_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            id,
            name,
            sha256,
            duration_ms,
            uploader,
            now
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(Ok(SoundClip {
            id: id.to_string(),
            name: name.to_owned(),
            sha256: to_hex(sha256),
            duration_ms,
            uploader_id: Some(uploader.to_string()),
            created_at: now,
        }))
    }

    /// Renames a clip. `Ok(None)` when no such clip exists.
    pub async fn rename_sound_clip(
        &self,
        id: SoundClipId,
        name: &str,
    ) -> anyhow::Result<Option<Result<SoundClip, SoundClipError>>> {
        let mut tx = self.begin_write().await?;
        let taken = sqlx::query_scalar!(
            "SELECT COUNT(*) FROM soundboard_clips WHERE name = ? AND id != ?",
            name,
            id
        )
        .fetch_one(&mut *tx)
        .await?;
        if taken > 0 {
            return Ok(Some(Err(SoundClipError::NameTaken)));
        }
        let updated = sqlx::query!(
            "UPDATE soundboard_clips SET name = ? WHERE id = ?",
            name,
            id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        if updated.rows_affected() == 0 {
            return Ok(None);
        }
        Ok(self.sound_clip(id).await?.map(Ok))
    }

    /// One clip, or None.
    pub async fn sound_clip(&self, id: SoundClipId) -> anyhow::Result<Option<SoundClip>> {
        let row = sqlx::query!(
            r#"SELECT id AS "id!: SoundClipId", name AS "name!", sha256 AS "sha256!",
                      duration_ms AS "duration_ms!", uploader_id AS "uploader_id?: UserId",
                      created_at AS "created_at!"
               FROM soundboard_clips WHERE id = ?"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| SoundClip {
            id: row.id.to_string(),
            name: row.name,
            sha256: to_hex(&row.sha256),
            duration_ms: row.duration_ms,
            uploader_id: row.uploader_id.map(|id| id.to_string()),
            created_at: row.created_at,
        }))
    }

    /// Removes a clip. Returns whether it existed. The bytes stay for the orphan sweep.
    pub async fn delete_sound_clip(&self, id: SoundClipId) -> anyhow::Result<bool> {
        let result = sqlx::query!("DELETE FROM soundboard_clips WHERE id = ?", id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }
}
