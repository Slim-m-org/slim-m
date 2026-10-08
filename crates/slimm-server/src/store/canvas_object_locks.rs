// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas objects locked in place; see migration `0101_canvas_object_locks.sql`.

use std::collections::HashSet;

use super::{Store, now_ms};
use crate::ids::{CanvasObjectId, ChannelId, UserId};

/// Why a lock or unlock was refused.
#[derive(Debug)]
pub enum LockError {
    /// No live object with that id in this channel.
    NotFound,
    /// Someone else's object, without `MANAGE_CANVAS`: the same rule a move uses.
    NotAuthorized,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for LockError {
    fn from(err: sqlx::Error) -> Self {
        LockError::Internal(err.into())
    }
}

impl From<anyhow::Error> for LockError {
    fn from(err: anyhow::Error) -> Self {
        LockError::Internal(err)
    }
}

impl Store {
    /// The live objects locked in `channel_id`.
    pub async fn list_canvas_object_locks(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Vec<CanvasObjectId>> {
        let ids = sqlx::query_scalar!(
            r#"SELECT l.object_id AS "object_id: CanvasObjectId"
               FROM canvas_object_locks l
               JOIN canvas_objects o ON o.id = l.object_id
               WHERE l.channel_id = ? AND o.deleted_at IS NULL
               ORDER BY l.locked_at"#,
            channel_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(ids)
    }

    /// Locks or unlocks `object_id`. Returns whether anything changed, so a
    /// repeat publishes nothing.
    pub async fn set_canvas_object_lock(
        &self,
        channel_id: ChannelId,
        object_id: CanvasObjectId,
        actor_id: UserId,
        may_moderate: bool,
        locked: bool,
    ) -> Result<bool, LockError> {
        let mut tx = self.begin_write().await?;
        let found = sqlx::query!(
            r#"SELECT author_id AS "author_id: UserId", deleted_at AS "deleted_at: i64"
               FROM canvas_objects WHERE id = ? AND channel_id = ?"#,
            object_id,
            channel_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(found) = found.filter(|f| f.deleted_at.is_none()) else {
            return Err(LockError::NotFound);
        };
        if !may_moderate && found.author_id != Some(actor_id) {
            return Err(LockError::NotAuthorized);
        }
        let changed = if locked {
            let now = now_ms();
            sqlx::query!(
                "INSERT INTO canvas_object_locks (object_id, channel_id, locked_by, locked_at)
                 VALUES (?, ?, ?, ?) ON CONFLICT (object_id) DO NOTHING",
                object_id,
                channel_id,
                actor_id,
                now
            )
            .execute(&mut *tx)
            .await?
            .rows_affected()
        } else {
            sqlx::query!(
                "DELETE FROM canvas_object_locks WHERE object_id = ?",
                object_id
            )
            .execute(&mut *tx)
            .await?
            .rows_affected()
        } == 1;
        tx.commit().await?;
        Ok(changed)
    }
}

/// Which of `ids` are locked, read inside an op's own write transaction so a
/// lock cannot land between the check and the change.
pub(super) async fn locked_among(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    ids: &[CanvasObjectId],
) -> Result<HashSet<CanvasObjectId>, sqlx::Error> {
    let mut locked = HashSet::new();
    for id in ids {
        let hit = sqlx::query_scalar!(
            r#"SELECT EXISTS(SELECT 1 FROM canvas_object_locks WHERE object_id = ?) AS "hit!: bool""#,
            id
        )
        .fetch_one(&mut **tx)
        .await?;
        if hit {
            locked.insert(*id);
        }
    }
    Ok(locked)
}
