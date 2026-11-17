// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Soundboard persistence: the Space's named audio clips.
//!
//! Shaped like `store/emoji.rs`: the bytes are an `attachments` row by sha256,
//! and this table adds the name, the validated duration and the cap.

use std::collections::HashSet;

use sqlx::SqliteConnection;

use super::{Store, now_ms};
use crate::ids::{EmojiId, SoundClipId, UserId};
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
    /// Null for a starter clip, or once the uploader's account has been deleted.
    pub uploader_id: Option<String>,
    pub created_at: i64,
    /// One standard emoji or a custom emoji's id, the encoding reactions use.
    pub emoji: Option<String>,
}

/// Why a write was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SoundClipError {
    /// Another clip already answers to this name.
    NameTaken,
    /// The Space is at [`MAX_SOUNDBOARD_CLIPS`].
    Full,
    /// No custom emoji answers to the id or name given.
    UnknownEmoji,
}

/// A clip's emoji as asked for. A custom one is looked up inside the write, so a
/// clip never names an emoji deleted under it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipEmoji<'a> {
    /// One standard emoji, stored as given.
    Standard(&'a str),
    /// A custom emoji by id.
    Custom(EmojiId),
    /// A custom emoji by name, stored as its id.
    Named(&'a str),
}

/// What an update changes: `None` leaves a field alone, and an emoji of `Some(None)` clears it.
#[derive(Debug, Clone, Copy, Default)]
pub struct SoundClipChange<'a> {
    pub name: Option<&'a str>,
    pub emoji: Option<Option<ClipEmoji<'a>>>,
}

/// One starter clip to offer, its bytes already stored.
#[derive(Debug, Clone, Copy)]
pub struct StarterClipRow<'a> {
    pub key: &'a str,
    pub id: SoundClipId,
    pub name: &'a str,
    pub sha256: &'a [u8],
    pub duration_ms: i64,
    pub emoji: &'a str,
}

/// The keys one seeding pass offered for the first time.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct StarterSeeded {
    /// Added as clips.
    pub added: Vec<String>,
    /// Recorded without a clip, because the name was taken or the Space was full.
    pub skipped: Vec<String>,
}

impl Store {
    /// Every clip, oldest first. Unpaginated: the set is capped.
    pub async fn list_sound_clips(&self) -> anyhow::Result<Vec<SoundClip>> {
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: SoundClipId", name AS "name!", sha256 AS "sha256!",
                      duration_ms AS "duration_ms!", uploader_id AS "uploader_id?: UserId",
                      created_at AS "created_at!", emoji
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
                emoji: row.emoji,
            })
            .collect())
    }

    /// Why adding a clip named `name` with `emoji` would be refused right now.
    /// Advisory: [`Store::create_sound_clip`] asks again inside its write transaction.
    pub async fn sound_clip_refusal(
        &self,
        name: &str,
        emoji: Option<ClipEmoji<'_>>,
    ) -> anyhow::Result<Option<SoundClipError>> {
        let mut conn = self.pool.acquire().await?;
        let count = sqlx::query_scalar!("SELECT COUNT(*) FROM soundboard_clips")
            .fetch_one(&mut *conn)
            .await?;
        if count >= MAX_SOUNDBOARD_CLIPS {
            return Ok(Some(SoundClipError::Full));
        }
        let taken =
            sqlx::query_scalar!("SELECT COUNT(*) FROM soundboard_clips WHERE name = ?", name)
                .fetch_one(&mut *conn)
                .await?;
        if taken > 0 {
            return Ok(Some(SoundClipError::NameTaken));
        }
        Ok(stored_emoji(&mut conn, emoji).await?.err())
    }

    /// Records a clip against already-written bytes, counted inside the write
    /// transaction so two concurrent uploads cannot both pass the cap.
    pub async fn create_sound_clip(
        &self,
        id: SoundClipId,
        name: &str,
        emoji: Option<ClipEmoji<'_>>,
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
        let emoji = match stored_emoji(&mut tx, emoji).await? {
            Ok(emoji) => emoji,
            Err(err) => return Ok(Err(err)),
        };
        sqlx::query!(
            "INSERT INTO soundboard_clips (id, name, sha256, duration_ms, uploader_id, created_at, emoji)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            id,
            name,
            sha256,
            duration_ms,
            uploader,
            now,
            emoji
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
            emoji,
        }))
    }

    /// Renames a clip, sets or clears its emoji, or both. `Ok(None)` when no such clip exists.
    pub async fn update_sound_clip(
        &self,
        id: SoundClipId,
        change: SoundClipChange<'_>,
    ) -> anyhow::Result<Option<Result<SoundClip, SoundClipError>>> {
        let mut tx = self.begin_write().await?;
        if let Some(name) = change.name {
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
        }
        let emoji = match change.emoji {
            None => None,
            Some(emoji) => match stored_emoji(&mut tx, emoji).await? {
                Ok(stored) => Some(stored),
                Err(err) => return Ok(Some(Err(err))),
            },
        };
        let sets_emoji = emoji.is_some();
        let emoji = emoji.flatten();
        let updated = sqlx::query!(
            "UPDATE soundboard_clips
             SET name = COALESCE(?, name), emoji = CASE WHEN ? THEN ? ELSE emoji END
             WHERE id = ?",
            change.name,
            sets_emoji,
            emoji,
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
                      created_at AS "created_at!", emoji
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
            emoji: row.emoji,
        }))
    }

    /// Removes a clip. Returns whether it existed. The bytes stay for the orphan sweep.
    pub async fn delete_sound_clip(&self, id: SoundClipId) -> anyhow::Result<bool> {
        let result = sqlx::query!("DELETE FROM soundboard_clips WHERE id = ?", id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    /// The starter keys this Space has been offered, whether or not they became clips.
    pub async fn offered_starter_clips(&self) -> anyhow::Result<HashSet<String>> {
        let keys = sqlx::query_scalar!(r#"SELECT key AS "key!" FROM soundboard_starter_offered"#)
            .fetch_all(&self.pool)
            .await?;
        Ok(keys.into_iter().collect())
    }

    /// Offers each row whose key is not in the ledger yet: added when its name is
    /// free and the Space has room, recorded either way, all in one transaction.
    pub async fn seed_sound_clips(
        &self,
        rows: &[StarterClipRow<'_>],
    ) -> anyhow::Result<StarterSeeded> {
        let mut tx = self.begin_write().await?;
        let now = now_ms();
        let mut count = sqlx::query_scalar!("SELECT COUNT(*) FROM soundboard_clips")
            .fetch_one(&mut *tx)
            .await?;
        let mut seeded = StarterSeeded::default();
        for row in rows {
            let recorded = sqlx::query!(
                "INSERT INTO soundboard_starter_offered (key, offered_at) VALUES (?, ?)
                 ON CONFLICT (key) DO NOTHING",
                row.key,
                now
            )
            .execute(&mut *tx)
            .await?
            .rows_affected();
            if recorded == 0 {
                continue;
            }
            let taken = sqlx::query_scalar!(
                "SELECT COUNT(*) FROM soundboard_clips WHERE name = ?",
                row.name
            )
            .fetch_one(&mut *tx)
            .await?;
            if taken > 0 || count >= MAX_SOUNDBOARD_CLIPS {
                seeded.skipped.push(row.key.to_owned());
                continue;
            }
            sqlx::query!(
                "INSERT INTO soundboard_clips (id, name, sha256, duration_ms, uploader_id, created_at, emoji)
                 VALUES (?, ?, ?, ?, NULL, ?, ?)",
                row.id,
                row.name,
                row.sha256,
                row.duration_ms,
                now,
                row.emoji
            )
            .execute(&mut *tx)
            .await?;
            count += 1;
            seeded.added.push(row.key.to_owned());
        }
        tx.commit().await?;
        Ok(seeded)
    }
}

/// The text a clip stores for `emoji`: a standard one as given, a custom one as
/// its id, refused when no custom emoji answers to it.
async fn stored_emoji(
    conn: &mut SqliteConnection,
    emoji: Option<ClipEmoji<'_>>,
) -> anyhow::Result<Result<Option<String>, SoundClipError>> {
    let custom = match emoji {
        None => return Ok(Ok(None)),
        Some(ClipEmoji::Standard(text)) => return Ok(Ok(Some(text.to_owned()))),
        Some(ClipEmoji::Custom(id)) => {
            sqlx::query_scalar!(
                r#"SELECT id AS "id!: EmojiId" FROM custom_emoji WHERE id = ?"#,
                id
            )
            .fetch_optional(&mut *conn)
            .await?
        }
        Some(ClipEmoji::Named(name)) => {
            let name = name.to_lowercase();
            sqlx::query_scalar!(
                r#"SELECT id AS "id!: EmojiId" FROM custom_emoji WHERE name = ?"#,
                name
            )
            .fetch_optional(&mut *conn)
            .await?
        }
    };
    Ok(custom
        .map(|id| Some(id.to_string()))
        .ok_or(SoundClipError::UnknownEmoji))
}
