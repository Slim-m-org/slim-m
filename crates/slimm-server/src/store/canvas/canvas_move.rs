// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one write that touches every geometry column at once: naming all four
//! in `UPDATE OF` is what fires the R-Tree trigger keeping `canvas_rtree`
//! (migration 0015) in sync.
//!
//! Split out of `canvas.rs`, which crossed the 500-line hard limit once
//! `move` needed both a pool-level wrapper (kept for `tests/canvas_index.rs`'s
//! own R-Tree assertions) and a transaction-level primitive
//! (`canvas_ops_apply::apply_move` calls it against its own write
//! transaction).

use sqlx::SqliteExecutor;

use super::super::Store;
use super::{PlaceError, valid_bounds};
use crate::ids::{CanvasObjectId, ChannelId, UserId};

impl Store {
    /// Moves or resizes an object outside any caller's transaction. Kept as a
    /// raw primitive over the pool for `tests/canvas_index.rs`'s own R-Tree
    /// assertions; `canvas_ops_apply::apply_move`'s authorized,
    /// op-stream-recorded move calls [`move_canvas_object_query`] directly,
    /// against its own write transaction, rather than this wrapper.
    pub async fn move_canvas_object(
        &self,
        id: CanvasObjectId,
        bounds: (f64, f64, f64, f64),
    ) -> Result<bool, PlaceError> {
        move_canvas_object_query(&self.pool, id, bounds).await
    }

    /// Whether `user` could move this live, unlocked object right now: the same
    /// rule a `move` op applies, asked before a drag preview is relayed.
    pub async fn canvas_object_movable_by(
        &self,
        channel_id: ChannelId,
        id: CanvasObjectId,
        user: UserId,
        may_moderate: bool,
    ) -> Result<bool, sqlx::Error> {
        let row = sqlx::query!(
            r#"SELECT author_id AS "author_id: UserId",
                      EXISTS(SELECT 1 FROM canvas_object_locks WHERE object_id = canvas_objects.id) AS "locked!: bool"
               FROM canvas_objects
               WHERE id = ? AND channel_id = ? AND deleted_at IS NULL"#,
            id,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some_and(|r| !r.locked && (may_moderate || r.author_id == Some(user))))
    }
}

/// Moves or resizes a live object, over either the pool or a caller's own
/// transaction. Named `UPDATE OF` columns are what fire the R-Tree trigger,
/// so this is the only write that has to touch all four.
pub(crate) async fn move_canvas_object_query<'e, E>(
    executor: E,
    id: CanvasObjectId,
    bounds: (f64, f64, f64, f64),
) -> Result<bool, PlaceError>
where
    E: SqliteExecutor<'e>,
{
    let (x, y, w, h) = bounds;
    if !valid_bounds(x, y, w, h) {
        return Err(PlaceError::OutOfBounds);
    }
    let affected = sqlx::query!(
        "UPDATE canvas_objects SET x = ?, y = ?, w = ?, h = ?
         WHERE id = ? AND deleted_at IS NULL",
        x,
        y,
        w,
        h,
        id
    )
    .execute(executor)
    .await?
    .rows_affected();
    Ok(affected > 0)
}
