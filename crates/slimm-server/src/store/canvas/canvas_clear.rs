// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a `clear` removes: every unlocked object under its fence and scope.
//! A clear that finds nothing unlocked takes the locked ones too, so a second
//! clear (decision 0085) is the way to empty a board with pinned items.

use super::canvas_ops_write::ClearScope;
use crate::ids::{CanvasObjectId, ChannelId};

/// The objects a clear soft-deleted, and the locked ones it left standing.
pub(in crate::store) struct ClearOutcome {
    pub(in crate::store) cleared: Vec<CanvasObjectId>,
    pub(in crate::store) spared: Vec<CanvasObjectId>,
}

pub(in crate::store) async fn apply_clear(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    before_seq: i64,
    scope: &ClearScope,
    now: i64,
) -> Result<ClearOutcome, sqlx::Error> {
    let cleared = clear_matching(tx, channel_id, before_seq, scope, now, true).await?;
    if cleared.is_empty() {
        let cleared = clear_matching(tx, channel_id, before_seq, scope, now, false).await?;
        return Ok(ClearOutcome {
            cleared,
            spared: Vec::new(),
        });
    }
    let spared = locked_matching(tx, channel_id, before_seq, scope).await?;
    Ok(ClearOutcome { cleared, spared })
}

async fn clear_matching(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    before_seq: i64,
    scope: &ClearScope,
    now: i64,
    skip_locked: bool,
) -> Result<Vec<CanvasObjectId>, sqlx::Error> {
    let kinds_json = scope.kinds_json();
    // RETURNING rather than rows_affected(): the audit log needs the ids.
    sqlx::query_scalar!(
        r#"UPDATE canvas_objects SET deleted_at = ?
           WHERE channel_id = ? AND deleted_at IS NULL AND seq <= ?
             AND (? IS NULL OR kind IN (SELECT value FROM json_each(?)))
             AND (? IS NULL OR author_id = ?)
             AND (? = 0 OR id NOT IN (SELECT object_id FROM canvas_object_locks))
           RETURNING id AS "id!: CanvasObjectId""#,
        now,
        channel_id,
        before_seq,
        kinds_json,
        kinds_json,
        scope.author_id,
        scope.author_id,
        skip_locked
    )
    .fetch_all(&mut **tx)
    .await
}

async fn locked_matching(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    before_seq: i64,
    scope: &ClearScope,
) -> Result<Vec<CanvasObjectId>, sqlx::Error> {
    let kinds_json = scope.kinds_json();
    sqlx::query_scalar!(
        r#"SELECT id AS "id!: CanvasObjectId" FROM canvas_objects
           WHERE channel_id = ? AND deleted_at IS NULL AND seq <= ?
             AND (? IS NULL OR kind IN (SELECT value FROM json_each(?)))
             AND (? IS NULL OR author_id = ?)
             AND id IN (SELECT object_id FROM canvas_object_locks)"#,
        channel_id,
        before_seq,
        kinds_json,
        kinds_json,
        scope.author_id,
        scope.author_id
    )
    .fetch_all(&mut **tx)
    .await
}
