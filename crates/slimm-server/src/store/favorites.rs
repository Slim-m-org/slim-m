// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One person's ordered favorites: GIFs and media kept from messages.
//!
//! See `migrations/0176_user_favorites.sql` for why this is its own table and
//! what each kind stores. Adding is idempotent twice over: the same entry id
//! and the same content both answer with the entry already held, so a retried
//! request and a double tap are indistinguishable from a first success.

use anyhow::Result;

use super::{Store, now_ms};
use crate::ids::{ChannelId, FavoriteId, MessageId, UserId};

/// Most favorites one account may hold, so a reader can always have the whole list.
pub const MAX_FAVORITES: i64 = 200;

/// Which kind of media an entry stands for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FavoriteKind {
    Gif,
    Attachment,
}

impl FavoriteKind {
    fn as_str(self) -> &'static str {
        match self {
            FavoriteKind::Gif => "gif",
            FavoriteKind::Attachment => "attachment",
        }
    }
}

/// What to store for a new favorite.
#[derive(Debug, Clone)]
pub enum NewFavorite {
    Gif {
        title: String,
        width: u32,
        height: u32,
        preview_url: String,
        full_url: String,
    },
    Attachment {
        sha256: Vec<u8>,
        message_id: MessageId,
        content_type: String,
        filename: String,
    },
}

/// One stored entry, with the live state of its source message.
#[derive(Debug, Clone)]
pub struct FavoriteRow {
    pub id: FavoriteId,
    pub kind: FavoriteKind,
    pub created_at: i64,
    pub title: String,
    pub width: i64,
    pub height: i64,
    pub gif_preview_url: Option<String>,
    pub gif_full_url: Option<String>,
    pub attachment_sha256: Option<Vec<u8>>,
    pub content_type: Option<String>,
    pub message_id: Option<MessageId>,
    /// The source message's channel while that message is live; `None` once it is gone.
    pub channel_id: Option<ChannelId>,
}

/// Why a favorite could not be added or reordered.
#[derive(Debug)]
pub enum FavoriteError {
    /// The account already holds [`MAX_FAVORITES`].
    TooMany,
    /// The id belongs to another account's entry.
    Taken,
    Internal(anyhow::Error),
}

impl From<anyhow::Error> for FavoriteError {
    fn from(err: anyhow::Error) -> Self {
        FavoriteError::Internal(err)
    }
}

impl From<sqlx::Error> for FavoriteError {
    fn from(err: sqlx::Error) -> Self {
        FavoriteError::Internal(err.into())
    }
}

struct RawRow {
    id: FavoriteId,
    kind: String,
    created_at: i64,
    title: String,
    width: i64,
    height: i64,
    gif_preview_url: Option<String>,
    gif_full_url: Option<String>,
    attachment_sha256: Option<Vec<u8>>,
    content_type: Option<String>,
    message_id: Option<MessageId>,
    channel_id: Option<ChannelId>,
}

impl From<RawRow> for FavoriteRow {
    fn from(r: RawRow) -> Self {
        FavoriteRow {
            id: r.id,
            kind: match r.kind.as_str() {
                "gif" => FavoriteKind::Gif,
                _ => FavoriteKind::Attachment,
            },
            created_at: r.created_at,
            title: r.title,
            width: r.width,
            height: r.height,
            gif_preview_url: r.gif_preview_url,
            gif_full_url: r.gif_full_url,
            attachment_sha256: r.attachment_sha256,
            content_type: r.content_type,
            message_id: r.message_id,
            channel_id: r.channel_id,
        }
    }
}

impl Store {
    /// Adds a favorite at the front of the list, or returns the entry already held.
    pub async fn add_favorite(
        &self,
        user_id: UserId,
        id: FavoriteId,
        new: &NewFavorite,
    ) -> std::result::Result<FavoriteRow, FavoriteError> {
        let mut tx = self.begin_write().await?;
        let owner = sqlx::query_scalar!(
            r#"SELECT user_id AS "user_id!: UserId" FROM user_favorites WHERE id = ?"#,
            id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if owner.is_some_and(|o| o != user_id) {
            tx.commit().await?;
            return Err(FavoriteError::Taken);
        }
        let existing = match new {
            NewFavorite::Gif { full_url, .. } => {
                sqlx::query_scalar!(
                    r#"SELECT id AS "id!: FavoriteId" FROM user_favorites
                       WHERE user_id = ? AND (id = ? OR (kind = 'gif' AND gif_full_url = ?))"#,
                    user_id,
                    id,
                    full_url
                )
                .fetch_optional(&mut *tx)
                .await?
            }
            NewFavorite::Attachment { sha256, .. } => {
                sqlx::query_scalar!(
                    r#"SELECT id AS "id!: FavoriteId" FROM user_favorites
                       WHERE user_id = ? AND (id = ? OR (kind = 'attachment' AND attachment_sha256 = ?))"#,
                    user_id,
                    id,
                    sha256
                )
                .fetch_optional(&mut *tx)
                .await?
            }
        };
        let held_id = match existing {
            Some(held) => held,
            None => {
                let held = sqlx::query_scalar!(
                    r#"SELECT COUNT(*) AS "n!: i64" FROM user_favorites WHERE user_id = ?"#,
                    user_id
                )
                .fetch_one(&mut *tx)
                .await?;
                if held >= MAX_FAVORITES {
                    tx.commit().await?;
                    return Err(FavoriteError::TooMany);
                }
                insert(&mut tx, user_id, id, new).await?;
                id
            }
        };
        tx.commit().await?;
        let row = self.favorite(user_id, held_id).await?;
        row.ok_or_else(|| FavoriteError::Internal(anyhow::anyhow!("favorite vanished after add")))
    }

    /// One entry, only when it is this account's.
    pub async fn favorite(&self, user_id: UserId, id: FavoriteId) -> Result<Option<FavoriteRow>> {
        let row = sqlx::query_as!(
            RawRow,
            r#"SELECT f.id AS "id!: FavoriteId", f.kind AS "kind!", f.created_at AS "created_at!",
                      f.title AS "title!", f.width AS "width!", f.height AS "height!",
                      f.gif_preview_url, f.gif_full_url,
                      f.attachment_sha256 AS "attachment_sha256: Vec<u8>", f.content_type,
                      f.message_id AS "message_id?: MessageId",
                      m.channel_id AS "channel_id?: ChannelId"
               FROM user_favorites f
               LEFT JOIN messages m ON m.id = f.message_id AND m.deleted_at IS NULL
               WHERE f.user_id = ? AND f.id = ?"#,
            user_id,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(Into::into))
    }

    /// The account's whole list in the order its owner arranged it.
    pub async fn list_favorites(&self, user_id: UserId) -> Result<Vec<FavoriteRow>> {
        let rows = sqlx::query_as!(
            RawRow,
            r#"SELECT f.id AS "id!: FavoriteId", f.kind AS "kind!", f.created_at AS "created_at!",
                      f.title AS "title!", f.width AS "width!", f.height AS "height!",
                      f.gif_preview_url, f.gif_full_url,
                      f.attachment_sha256 AS "attachment_sha256: Vec<u8>", f.content_type,
                      f.message_id AS "message_id?: MessageId",
                      m.channel_id AS "channel_id?: ChannelId"
               FROM user_favorites f
               LEFT JOIN messages m ON m.id = f.message_id AND m.deleted_at IS NULL
               WHERE f.user_id = ? ORDER BY f.position, f.id"#,
            user_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    /// Removes an entry; a no-op on one that is not there.
    pub async fn remove_favorite(&self, user_id: UserId, id: FavoriteId) -> Result<()> {
        sqlx::query!(
            "DELETE FROM user_favorites WHERE user_id = ? AND id = ?",
            user_id,
            id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Puts the named entries first, in the order given; entries not named keep
    /// their relative order after them, so a stale client cannot lose an entry.
    pub async fn reorder_favorites(&self, user_id: UserId, ids: &[FavoriteId]) -> Result<()> {
        let mut tx = self.begin_write().await?;
        let current = sqlx::query_scalar!(
            r#"SELECT id AS "id!: FavoriteId" FROM user_favorites
               WHERE user_id = ? ORDER BY position, id"#,
            user_id
        )
        .fetch_all(&mut *tx)
        .await?;
        let named: Vec<FavoriteId> = ids
            .iter()
            .copied()
            .filter(|i| current.contains(i))
            .collect();
        let rest = current.iter().copied().filter(|i| !named.contains(i));
        for (position, id) in named.iter().copied().chain(rest).enumerate() {
            let position = position as i64;
            sqlx::query!(
                "UPDATE user_favorites SET position = ? WHERE user_id = ? AND id = ?",
                position,
                user_id,
                id
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// The attachment as it is linked to a live message, so a favorite can only
    /// name a file that message really carries.
    pub async fn live_message_attachment(
        &self,
        message_id: MessageId,
        sha256: &[u8],
    ) -> Result<Option<(String, String)>> {
        let row = sqlx::query!(
            r#"SELECT a.content_type AS "content_type!", a.filename AS "filename!",
                      ma.filename AS "linked_name?: String"
               FROM message_attachments ma
               JOIN messages m ON m.id = ma.message_id AND m.deleted_at IS NULL
               JOIN attachments a ON a.sha256 = ma.sha256
               WHERE ma.message_id = ? AND ma.sha256 = ?"#,
            message_id,
            sha256
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| (r.content_type, r.linked_name.unwrap_or(r.filename))))
    }
}

async fn insert(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
    id: FavoriteId,
    new: &NewFavorite,
) -> std::result::Result<(), sqlx::Error> {
    let now = now_ms();
    let front = sqlx::query_scalar!(
        r#"SELECT COALESCE(MIN(position), 0) - 1 AS "p!: i64" FROM user_favorites WHERE user_id = ?"#,
        user_id
    )
    .fetch_one(&mut **tx)
    .await?;
    match new {
        NewFavorite::Gif {
            title,
            width,
            height,
            preview_url,
            full_url,
        } => {
            let (kind, w, h) = (FavoriteKind::Gif.as_str(), *width as i64, *height as i64);
            sqlx::query!(
                "INSERT INTO user_favorites
                   (id, user_id, kind, position, created_at, title, width, height,
                    gif_preview_url, gif_full_url)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                id,
                user_id,
                kind,
                front,
                now,
                title,
                w,
                h,
                preview_url,
                full_url
            )
            .execute(&mut **tx)
            .await?;
        }
        NewFavorite::Attachment {
            sha256,
            message_id,
            content_type,
            filename,
        } => {
            let kind = FavoriteKind::Attachment.as_str();
            sqlx::query!(
                "INSERT INTO user_favorites
                   (id, user_id, kind, position, created_at, title,
                    attachment_sha256, content_type, message_id)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                id,
                user_id,
                kind,
                front,
                now,
                filename,
                sha256,
                content_type,
                message_id
            )
            .execute(&mut **tx)
            .await?;
        }
    }
    Ok(())
}
