// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing erased canvas content for good (decision 0085): a moderator purge of one object, and the sweep that deletes objects erased longer ago than their channel's message retention window, which is the channel's own override when it has one and the space's otherwise (nothing when that is off), and the eviction that keeps a channel's erased objects under its cap.
//! A hard delete takes the object, its ops, targets, audit rows, lock and attachment link; the swept watermark rises to the highest seq removed so `list_canvas_ops` resets cursors behind it.

use sqlx::QueryBuilder;

use super::super::{Store, now_ms};
use super::canvas_ops_sweep::raise_swept_watermark;
use super::{CanvasObject, fetch_object};
use crate::ids::{CanvasObjectId, ChannelId};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
/// Objects deleted per transaction, and the bound-variable count of its `IN` lists.
const PURGE_BATCH: usize = 200;
/// Batches per tick, so a huge backlog drains over several ticks instead of stalling writers.
const PURGE_BATCHES_PER_TICK: usize = 25;

/// Erased objects a channel always keeps for undo, however low its object cap is set.
const ERASED_KEPT_FLOOR: i64 = super::MAX_OBJECTS_PER_CHANNEL;

/// Why a purge was refused.
#[derive(Debug)]
pub enum PurgeError {
    /// No such object in this channel.
    NotFound,
    /// The object is live; erase it before purging.
    StillLive,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for PurgeError {
    fn from(err: sqlx::Error) -> Self {
        PurgeError::Internal(err.into())
    }
}

fn in_list(builder: &mut QueryBuilder<sqlx::Sqlite>, ids: &[CanvasObjectId]) {
    builder.push(" IN (");
    let mut separated = builder.separated(", ");
    for id in ids {
        separated.push_bind(*id);
    }
    builder.push(")");
}

async fn delete_where_in(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    statement: &str,
    ids: &[CanvasObjectId],
) -> Result<(), sqlx::Error> {
    let mut builder = QueryBuilder::new(statement);
    in_list(&mut builder, ids);
    builder.build().execute(&mut **tx).await?;
    Ok(())
}

/// Hard-deletes erased `ids` of one channel inside the caller's write transaction.
pub(super) async fn hard_delete(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    ids: &[CanvasObjectId],
) -> Result<(), sqlx::Error> {
    let mut builder =
        QueryBuilder::new("SELECT DISTINCT seq FROM canvas_op_targets WHERE channel_id = ");
    builder.push_bind(channel_id);
    builder.push(" AND object_id");
    in_list(&mut builder, ids);
    let seqs: Vec<i64> = builder.build_query_scalar().fetch_all(&mut **tx).await?;

    delete_where_in(tx, "DELETE FROM canvas_audit_log WHERE object_id", ids).await?;
    delete_where_in(
        tx,
        "DELETE FROM canvas_object_attachments WHERE object_id",
        ids,
    )
    .await?;
    delete_where_in(tx, "DELETE FROM canvas_op_targets WHERE object_id", ids).await?;

    let mut gone = Vec::new();
    // Restores first: they name the ops that are about to lose their targets.
    for restores in [true, false] {
        for chunk in seqs.chunks(PURGE_BATCH) {
            let mut builder = QueryBuilder::new("DELETE FROM canvas_ops WHERE channel_id = ");
            builder.push_bind(channel_id);
            builder.push(if restores {
                " AND kind = 'restore'"
            } else {
                " AND kind NOT IN ('clear', 'restore')
                  AND NOT EXISTS (SELECT 1 FROM canvas_ops r WHERE r.target_op = canvas_ops.id)"
            });
            builder.push(
                " AND NOT EXISTS (SELECT 1 FROM canvas_op_targets t
                    WHERE t.channel_id = canvas_ops.channel_id AND t.seq = canvas_ops.seq)
                  AND seq IN (",
            );
            let mut separated = builder.separated(", ");
            for seq in chunk {
                separated.push_bind(*seq);
            }
            builder.push(") RETURNING seq");
            let rows: Vec<i64> = builder.build_query_scalar().fetch_all(&mut **tx).await?;
            gone.extend(rows);
        }
    }
    delete_where_in(tx, "DELETE FROM canvas_objects WHERE id", ids).await?;
    let swept: Vec<(ChannelId, i64)> = gone.into_iter().map(|seq| (channel_id, seq)).collect();
    raise_swept_watermark(tx, &swept).await
}

impl Store {
    /// Permanently removes one erased object and returns the row it held, so
    /// the deleter can undo. The caller erases a live object first so every
    /// client drops it; this then deletes the rows.
    pub async fn purge_canvas_object(
        &self,
        channel_id: ChannelId,
        object_id: CanvasObjectId,
    ) -> Result<CanvasObject, PurgeError> {
        let mut tx = self.begin_write().await?;
        let (object_channel, dead, object) = fetch_object(&mut tx, object_id)
            .await
            .map_err(PurgeError::Internal)?
            .ok_or(PurgeError::NotFound)?;
        if object_channel != channel_id {
            return Err(PurgeError::NotFound);
        }
        if !dead {
            return Err(PurgeError::StillLive);
        }
        hard_delete(&mut tx, channel_id, &[object_id]).await?;
        tx.commit().await?;
        Ok(object)
    }

    /// Deletes objects erased before their channel's retention window; returns how many.
    pub(super) async fn purge_erased_canvas_objects(&self) -> anyhow::Result<u64> {
        let space_days = self.message_retention_days().await?;
        let now = now_ms();
        let mut purged = 0u64;
        for _ in 0..PURGE_BATCHES_PER_TICK {
            let mut tx = self.begin_write().await?;
            let due = sqlx::query!(
                r#"SELECT obj.id AS "id!: CanvasObjectId", obj.channel_id AS "channel_id!: ChannelId"
                   FROM canvas_objects obj
                   JOIN channels c ON c.id = obj.channel_id
                   LEFT JOIN messages pm ON pm.id = c.parent_message_id
                   LEFT JOIN channel_retention cr ON cr.channel_id = COALESCE(pm.channel_id, c.id)
                   WHERE obj.deleted_at IS NOT NULL
                     AND COALESCE(cr.retention_days, ?1) > 0
                     AND obj.deleted_at < ?2 - COALESCE(cr.retention_days, ?1) * ?3
                   ORDER BY obj.deleted_at LIMIT ?4"#,
                space_days,
                now,
                DAY_MS,
                PURGE_BATCH as i64
            )
            .fetch_all(&mut *tx)
            .await?;
            if due.is_empty() {
                break;
            }
            let mut by_channel: std::collections::HashMap<ChannelId, Vec<CanvasObjectId>> =
                std::collections::HashMap::new();
            for row in &due {
                by_channel.entry(row.channel_id).or_default().push(row.id);
            }
            for (channel_id, ids) in by_channel {
                hard_delete(&mut tx, channel_id, &ids).await?;
            }
            tx.commit().await?;
            purged += due.len() as u64;
        }
        purged += self.drain_erased_backlog().await?;
        Ok(purged)
    }

    /// Brings channels already past the erased ceiling back under it, one batch at a time.
    async fn drain_erased_backlog(&self) -> anyhow::Result<u64> {
        let mut tx = self.begin_write().await?;
        let ceiling = erased_ceiling(super::super::space::read_canvas_object_cap(&mut *tx).await?);
        let over = sqlx::query_scalar!(
            r#"SELECT channel_id AS "channel_id!: ChannelId" FROM canvas_objects
               WHERE deleted_at IS NOT NULL
               GROUP BY channel_id HAVING COUNT(*) > ?"#,
            ceiling
        )
        .fetch_all(&mut *tx)
        .await?;
        tx.commit().await?;
        let mut evicted = 0u64;
        let mut batches = 0;
        for channel_id in over {
            while batches < PURGE_BATCHES_PER_TICK {
                let mut tx = self.begin_write().await?;
                let excess = erased_count(&mut tx, channel_id).await? - ceiling;
                let taken = if excess > 0 {
                    evict_oldest(&mut tx, channel_id, excess.min(PURGE_BATCH as i64)).await?
                } else {
                    0
                };
                tx.commit().await?;
                batches += 1;
                if taken == 0 {
                    break;
                }
                evicted += taken as u64;
            }
        }
        Ok(evicted)
    }
}

/// Hard-deletes a channel's oldest self-erased objects (lowest seq first) until `adding` more fit under the erased ceiling, twice `cap` or [`ERASED_KEPT_FLOOR`] if higher; at most `adding` plus one batch per call, and a moderator's erasures, which have audit rows, are never taken.
pub(super) async fn evict_erased_over_cap(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    adding: i64,
    cap: i64,
) -> Result<(), sqlx::Error> {
    let erased = erased_count(tx, channel_id).await?;
    let excess = erased + adding - erased_ceiling(cap);
    let mut left = excess.min(adding + PURGE_BATCH as i64);
    while left > 0 {
        let evicted = evict_oldest(tx, channel_id, left.min(PURGE_BATCH as i64)).await?;
        if evicted == 0 {
            break;
        }
        left -= evicted;
    }
    Ok(())
}

fn erased_ceiling(cap: i64) -> i64 {
    cap.max(ERASED_KEPT_FLOOR) * 2
}

async fn erased_count(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!: i64" FROM canvas_objects
           WHERE channel_id = ? AND deleted_at IS NOT NULL"#,
        channel_id
    )
    .fetch_one(&mut **tx)
    .await
}

/// Hard-deletes up to `limit` of the channel's oldest erased objects that carry no audit row; returns how many.
async fn evict_oldest(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    limit: i64,
) -> Result<i64, sqlx::Error> {
    let oldest = sqlx::query_scalar!(
        r#"SELECT id AS "id!: CanvasObjectId" FROM canvas_objects
           WHERE channel_id = ? AND deleted_at IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM canvas_audit_log a WHERE a.object_id = canvas_objects.id)
           ORDER BY seq LIMIT ?"#,
        channel_id,
        limit
    )
    .fetch_all(&mut **tx)
    .await?;
    if oldest.is_empty() {
        return Ok(0);
    }
    hard_delete(tx, channel_id, &oldest).await?;
    Ok(oldest.len() as i64)
}
