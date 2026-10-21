// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing erased canvas content for good (decision 0085): a moderator purge of one object, and the sweep that deletes objects erased longer ago than the space's message retention window (nothing when retention is off).
//! A hard delete takes the object, its ops, targets, audit rows, lock and attachment link; the swept watermark rises to the highest seq removed so `list_canvas_ops` resets cursors behind it.

use sqlx::QueryBuilder;

use super::super::{Store, now_ms};
use super::canvas_ops_sweep::raise_swept_watermark;
use crate::ids::{CanvasObjectId, ChannelId};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
/// Objects deleted per transaction, and the bound-variable count of its `IN` lists.
const PURGE_BATCH: usize = 200;
/// Batches per tick, so a huge backlog drains over several ticks instead of stalling writers.
const PURGE_BATCHES_PER_TICK: usize = 25;

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

fn in_list<'a>(builder: &mut QueryBuilder<'a, sqlx::Sqlite>, ids: &'a [CanvasObjectId]) {
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
async fn hard_delete(
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
    /// Permanently removes one erased object, for a moderator. The caller erases
    /// a live object first so every client drops it; this then deletes the rows.
    pub async fn purge_canvas_object(
        &self,
        channel_id: ChannelId,
        object_id: CanvasObjectId,
    ) -> Result<(), PurgeError> {
        let mut tx = self.begin_write().await?;
        let found = sqlx::query_scalar!(
            r#"SELECT deleted_at IS NOT NULL AS "dead!: bool" FROM canvas_objects
               WHERE id = ? AND channel_id = ?"#,
            object_id,
            channel_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        match found {
            None => return Err(PurgeError::NotFound),
            Some(false) => return Err(PurgeError::StillLive),
            Some(true) => {}
        }
        hard_delete(&mut tx, channel_id, &[object_id]).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Deletes objects erased before the retention window; returns how many.
    pub(super) async fn purge_erased_canvas_objects(&self) -> anyhow::Result<u64> {
        let days = self.message_retention_days().await?;
        if days <= 0 {
            return Ok(0);
        }
        let cutoff = now_ms() - days * DAY_MS;
        let mut purged = 0u64;
        for _ in 0..PURGE_BATCHES_PER_TICK {
            let mut tx = self.begin_write().await?;
            let due = sqlx::query!(
                r#"SELECT id AS "id!: CanvasObjectId", channel_id AS "channel_id!: ChannelId"
                   FROM canvas_objects WHERE deleted_at IS NOT NULL AND deleted_at < ?
                   ORDER BY deleted_at LIMIT ?"#,
                cutoff,
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
        Ok(purged)
    }
}
