// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Custom emoji persistence: the deployment's named images.
//!
//! The bytes are not stored here. An emoji points at an `attachments` row by
//! sha256 and reuses that table's on-disk blob, so an image uploaded twice, or
//! one whose bytes already exist because someone attached them to a message,
//! costs one copy. See `migrations/0016_custom_emoji.sql` for why the name and
//! its uniqueness are the only things this table adds.

use super::{Store, now_ms};
use crate::ids::{EmojiId, UserId};
use crate::media::to_hex;

/// Most emoji one deployment may hold. Every client lists all of them to
/// render `:shortcode:` at all, so this bounds a response nothing paginates.
pub const MAX_CUSTOM_EMOJI: i64 = 500;

/// One custom emoji as a client needs it: the name it is typed by and the id
/// its image is fetched at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustomEmoji {
    pub id: String,
    pub name: String,
    /// Hex sha256, the same id an attachment's bytes are fetched by.
    pub sha256: String,
    /// Null once the uploader's account has been deleted.
    pub uploader_id: Option<String>,
    pub created_at: i64,
}

/// Why an upload was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreateEmojiError {
    /// Another emoji already answers to this name.
    NameTaken,
    /// The deployment is at [`MAX_CUSTOM_EMOJI`].
    Full,
}

impl Store {
    /// Every custom emoji, oldest first. Unpaginated on purpose: a client
    /// needs the whole set to render any message, and the set is capped.
    pub async fn list_custom_emoji(&self) -> anyhow::Result<Vec<CustomEmoji>> {
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: EmojiId", name AS "name!",
                      sha256 AS "sha256!", uploader_id AS "uploader_id?: UserId",
                      created_at AS "created_at!"
               FROM custom_emoji
               ORDER BY created_at ASC, rowid ASC"#
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| CustomEmoji {
                id: row.id.to_string(),
                name: row.name,
                sha256: to_hex(&row.sha256),
                uploader_id: row.uploader_id.map(|id| id.to_string()),
                created_at: row.created_at,
            })
            .collect())
    }

    /// Why creating an emoji named `name` would be refused right now, or
    /// `None` if it would be accepted.
    ///
    /// Asked before any bytes are written, so a refusal costs nothing and
    /// leaves nothing behind. Advisory by construction: two callers can both
    /// read a count below the cap and both go on to write, which is why
    /// [`Store::create_custom_emoji`] asks again inside its own write
    /// transaction and stays the only authority on the answer.
    pub async fn custom_emoji_refusal(
        &self,
        name: &str,
    ) -> anyhow::Result<Option<CreateEmojiError>> {
        let count = sqlx::query_scalar!("SELECT COUNT(*) FROM custom_emoji")
            .fetch_one(&self.pool)
            .await?;
        if count as i64 >= MAX_CUSTOM_EMOJI {
            return Ok(Some(CreateEmojiError::Full));
        }

        let taken = sqlx::query_scalar!("SELECT COUNT(*) FROM custom_emoji WHERE name = ?", name)
            .fetch_one(&self.pool)
            .await?;
        Ok((taken > 0).then_some(CreateEmojiError::NameTaken))
    }

    /// Records an emoji against already-written bytes.
    ///
    /// Write-locked and counted inside the same transaction as the insert:
    /// the cap is only a cap if two concurrent uploads cannot both read a
    /// count below it and then both write.
    ///
    /// `uploader` is `None` for the bulk import, which runs from an operator's
    /// shell rather than an authenticated session, so there is no account to
    /// name. The column is already nullable for the account-deletion case, and
    /// a client renders both the same way: nobody to attribute it to.
    pub async fn create_custom_emoji(
        &self,
        id: EmojiId,
        name: &str,
        sha256: &[u8],
        uploader: Option<UserId>,
    ) -> anyhow::Result<Result<CustomEmoji, CreateEmojiError>> {
        let mut tx = self.begin_write().await?;
        let now = now_ms();
        let count = sqlx::query_scalar!("SELECT COUNT(*) FROM custom_emoji")
            .fetch_one(&mut *tx)
            .await?;
        if count as i64 >= MAX_CUSTOM_EMOJI {
            return Ok(Err(CreateEmojiError::Full));
        }

        let taken = sqlx::query_scalar!("SELECT COUNT(*) FROM custom_emoji WHERE name = ?", name)
            .fetch_one(&mut *tx)
            .await?;
        if taken > 0 {
            return Ok(Err(CreateEmojiError::NameTaken));
        }

        sqlx::query!(
            "INSERT INTO custom_emoji (id, name, sha256, uploader_id, created_at)
             VALUES (?, ?, ?, ?, ?)",
            id,
            name,
            sha256,
            uploader,
            now
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        Ok(Ok(CustomEmoji {
            id: id.to_string(),
            name: name.to_owned(),
            sha256: to_hex(sha256),
            uploader_id: uploader.map(|id| id.to_string()),
            created_at: now,
        }))
    }

    /// Creates every emoji in `rows` as one transaction: either the whole
    /// batch lands or none of it does.
    ///
    /// Reuses [`Self::create_custom_emoji`]'s own cap-and-name check, but runs
    /// it once against the whole batch rather than once per row: the cap is
    /// checked against `rows.len()` all at once, and each name is checked
    /// against both the existing table and the rows already inserted earlier
    /// in this same transaction, so two rows in one batch that share a name
    /// cannot both read a count below the cap and both go on to write, the
    /// same race the single insert closes for one row at a time. A row that
    /// fails either check rolls the whole transaction back (dropping it
    /// uncommitted, same as the single path's own early return), naming which
    /// index and why so the caller can report it the way [`refused`] already
    /// reports a single refusal.
    ///
    /// [`refused`]: crate::emoji::refused
    pub async fn create_custom_emoji_batch(
        &self,
        rows: Vec<(EmojiId, String, Vec<u8>)>,
        uploader: Option<UserId>,
    ) -> anyhow::Result<Result<Vec<CustomEmoji>, (usize, CreateEmojiError)>> {
        if rows.is_empty() {
            return Ok(Ok(Vec::new()));
        }
        let mut tx = self.begin_write().await?;
        let now = now_ms();

        let count = sqlx::query_scalar!("SELECT COUNT(*) FROM custom_emoji")
            .fetch_one(&mut *tx)
            .await?;
        if count as i64 + rows.len() as i64 > MAX_CUSTOM_EMOJI {
            return Ok(Err((0, CreateEmojiError::Full)));
        }

        for (index, (id, name, sha256)) in rows.iter().enumerate() {
            let taken =
                sqlx::query_scalar!("SELECT COUNT(*) FROM custom_emoji WHERE name = ?", name)
                    .fetch_one(&mut *tx)
                    .await?;
            if taken > 0 {
                return Ok(Err((index, CreateEmojiError::NameTaken)));
            }
            sqlx::query!(
                "INSERT INTO custom_emoji (id, name, sha256, uploader_id, created_at)
                 VALUES (?, ?, ?, ?, ?)",
                id,
                name,
                sha256,
                uploader,
                now
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;

        Ok(Ok(rows
            .into_iter()
            .map(|(id, name, sha256)| CustomEmoji {
                id: id.to_string(),
                name,
                sha256: to_hex(&sha256),
                uploader_id: uploader.map(|id| id.to_string()),
                created_at: now,
            })
            .collect()))
    }

    /// The bytes the emoji of this name points at, or None if no emoji
    /// answers to it. The bulk import asks this to tell "already imported"
    /// from "this name belongs to a different image".
    pub async fn custom_emoji_sha256_by_name(&self, name: &str) -> anyhow::Result<Option<Vec<u8>>> {
        let row = sqlx::query!(
            r#"SELECT sha256 AS "sha256!" FROM custom_emoji WHERE name = ?"#,
            name
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| row.sha256))
    }

    /// The bytes an emoji points at, or None if no such emoji exists.
    pub async fn custom_emoji_sha256(&self, id: EmojiId) -> anyhow::Result<Option<Vec<u8>>> {
        let row = sqlx::query!(
            r#"SELECT sha256 AS "sha256!" FROM custom_emoji WHERE id = ?"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| row.sha256))
    }

    /// Removes an emoji. Returns whether it existed, so a repeated delete is
    /// idempotent rather than an error.
    ///
    /// The bytes are left behind deliberately: another emoji or a message may
    /// reference the same hash, and the orphan sweep is what reclaims a hash
    /// nothing points at any more.
    pub async fn delete_custom_emoji(&self, id: EmojiId) -> anyhow::Result<bool> {
        let result = sqlx::query!("DELETE FROM custom_emoji WHERE id = ?", id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }
}
