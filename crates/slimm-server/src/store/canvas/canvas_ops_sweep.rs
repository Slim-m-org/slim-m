// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Compacting `canvas_ops`: reclaiming `remove`, `clear` and `restore` rows
//! once nothing they did is still in effect, on the same periodic-sweep
//! model as [`Store::sweep_expired_tokens`] and
//! [`Store::sweep_orphaned_attachments`].
//!
//! `docs/ROADMAP.md`'s Phase 6 line asks for retention that "exempts rows
//! tied to open moderation reports" - checked against `store/reports.rs`
//! rather than assumed, and it does not apply: a report never references a
//! canvas object or op at all, so there is nothing there to exempt. The real
//! constraint is undo reachability instead: a `remove` or `clear` must
//! survive for as long as restoring it would still touch something, or
//! deleting it makes that specific deletion permanently un-undoable. That is
//! narrower than "anything it touched is still dead": an object a *later,
//! unrelated* op re-removed is still dead, but restoring the older op would
//! not touch it any more - `apply_restore` fences a `remove`'s own targets on
//! the exact `deleted_at` timestamp that removal set, not on bare deadness
//! (see its own doc), and both sweep passes below check the identical fence
//! for exactly that reason. `place` rows
//! are never touched by any of this - `list_canvas_ops`'s own join reads a
//! placed object straight off the `place` row's own seq, so deleting one
//! would delete the object from every future replay, not the object's
//! history.
//!
//! `restore.target_op` is a plain foreign key onto `canvas_ops.id` with no
//! `ON DELETE` clause, so a `remove` or `clear` cannot be deleted while any
//! `restore` row still names it, however old that removal already is. That
//! is why this runs in two passes: eligible restores first (age alone gates
//! them, since nothing ever points at a restore's own id - `apply_restore`
//! refuses a target that is not itself a `remove` or `clear`), then removes
//! and clears, bounded by age *and* by having no remaining unrestored target
//! *and* no remaining referencing restore. `canvas_op_targets` needs no
//! cleanup of its own: its `(channel_id, seq)` foreign key already cascades.
//!
//! Nothing here changes what a compacted floor means to a reading client:
//! `list_canvas_ops` already recomputes `MIN(seq)` on every read and answers
//! `reset` to a cursor that falls behind it, the same mechanism
//! `message_ops` uses. A swept `remove`/`clear`/`restore` pair nets to no
//! visible change for any replay that crosses it - by construction, since it
//! is only ever swept once every object it named is back in the state it
//! held before that op ran - so a client that pages straight across the gap
//! arrives at the same answer either way.
//!
//! One shape does change a replay: a `clear` between a `remove` and the
//! `restore` that undoes it. The pair is kept then, or a replay from a swept
//! log would apply the clear to an object the restore had brought back. A
//! client whose cursor sits inside a gap this leaves behind cannot be told
//! from one paging a fresh replay, so the highest swept seq is kept per
//! channel as a watermark and `list_canvas_ops` resets any cursor behind it.
//! Past the space's message retention window, erased objects are removed for
//! good as well; see `canvas_purge`.

use super::super::{Store, now_ms};
use crate::ids::ChannelId;

/// Roughly the roadmap's own number for the op log; unrelated to
/// `canvas_audit_log`'s own retention, which this sweep never touches.
pub const CANVAS_OP_RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// Bounds how long one pass can hold the write lock, the same reasoning
/// `ORPHAN_SWEEP_BATCH` documents for the attachment sweep.
const CANVAS_OP_SWEEP_BATCH: i64 = 500;

/// How many rows one sweep pass reclaimed, by kind.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct SweptCanvasOps {
    pub restores: u64,
    pub removes: u64,
    pub clears: u64,
    /// Erased objects removed for good once past message retention.
    pub purged: u64,
}

impl SweptCanvasOps {
    pub fn total(&self) -> u64 {
        self.restores + self.removes + self.clears + self.purged
    }
}

/// Records that ops up to each channel's highest swept seq are gone, so cursors behind it reset.
pub(super) async fn raise_swept_watermark(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    swept: &[(ChannelId, i64)],
) -> Result<(), sqlx::Error> {
    let mut highest: std::collections::HashMap<ChannelId, i64> = std::collections::HashMap::new();
    for (channel_id, seq) in swept {
        let slot = highest.entry(*channel_id).or_insert(*seq);
        *slot = (*slot).max(*seq);
    }
    for (channel_id, seq) in highest {
        sqlx::query!(
            "INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
             VALUES (?, 'canvas_swept', ?)
             ON CONFLICT (channel_id, stream) DO UPDATE SET next_seq = MAX(next_seq, excluded.next_seq)",
            channel_id,
            seq
        )
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

impl Store {
    /// Deletes canvas ops old enough, and no longer needed to undo anything,
    /// across every channel. See the module doc for the retention rule.
    pub async fn sweep_canvas_ops(&self) -> anyhow::Result<SweptCanvasOps> {
        let cutoff = now_ms() - CANVAS_OP_RETENTION_MS;
        let mut tx = self.begin_write().await?;

        // Pass 1: restores, gated on age alone, unless a clear separates them from their remove.
        let restores = sqlx::query!(
            r#"DELETE FROM canvas_ops WHERE id IN (
                   SELECT o.id FROM canvas_ops o
                   WHERE o.kind = 'restore' AND o.created_at < ?1
                     AND NOT EXISTS (
                         SELECT 1 FROM canvas_ops t
                         JOIN canvas_ops c ON c.channel_id = t.channel_id AND c.kind = 'clear'
                           AND c.seq > t.seq AND c.seq < o.seq
                         WHERE t.id = o.target_op
                     )
                   LIMIT ?2
               )
               RETURNING channel_id AS "channel_id!: ChannelId", seq AS "seq!: i64""#,
            cutoff,
            CANVAS_OP_SWEEP_BATCH
        )
        .fetch_all(&mut *tx)
        .await?;

        // Pass 2a: removes, guarded by the same exact-timestamp fence `apply_restore` checks.
        let removes = sqlx::query!(
            r#"DELETE FROM canvas_ops WHERE id IN (
                   SELECT o.id FROM canvas_ops o
                   WHERE o.kind = 'remove'
                     AND o.created_at < ?1
                     AND NOT EXISTS (
                         SELECT 1 FROM canvas_ops r
                         WHERE r.kind = 'restore' AND r.target_op = o.id
                     )
                     AND NOT EXISTS (
                         SELECT 1 FROM canvas_op_targets t
                         JOIN canvas_objects obj
                           ON obj.id = t.object_id AND obj.channel_id = t.channel_id
                         WHERE t.channel_id = o.channel_id AND t.seq = o.seq
                           AND obj.deleted_at = o.created_at
                     )
                   LIMIT ?2
               )
               RETURNING channel_id AS "channel_id!: ChannelId", seq AS "seq!: i64""#,
            cutoff,
            CANVAS_OP_SWEEP_BATCH
        )
        .fetch_all(&mut *tx)
        .await?;

        // Pass 2b: clears, guarded by the exact-timestamp fence restore_candidates uses.
        let clears = sqlx::query!(
            r#"DELETE FROM canvas_ops WHERE id IN (
                   SELECT o.id FROM canvas_ops o
                   WHERE o.kind = 'clear'
                     AND o.created_at < ?1
                     AND NOT EXISTS (
                         SELECT 1 FROM canvas_ops r
                         WHERE r.kind = 'restore' AND r.target_op = o.id
                     )
                     AND NOT EXISTS (
                         SELECT 1 FROM canvas_objects obj
                         WHERE obj.channel_id = o.channel_id
                           AND obj.seq <= o.bound_seq
                           AND obj.deleted_at = o.created_at
                     )
                   LIMIT ?2
               )
               RETURNING channel_id AS "channel_id!: ChannelId", seq AS "seq!: i64""#,
            cutoff,
            CANVAS_OP_SWEEP_BATCH
        )
        .fetch_all(&mut *tx)
        .await?;

        let swept: Vec<(ChannelId, i64)> = restores
            .iter()
            .map(|row| (row.channel_id, row.seq))
            .chain(removes.iter().map(|row| (row.channel_id, row.seq)))
            .chain(clears.iter().map(|row| (row.channel_id, row.seq)))
            .collect();
        raise_swept_watermark(&mut tx, &swept).await?;
        tx.commit().await?;

        let purged = self.purge_erased_canvas_objects().await?;
        Ok(SweptCanvasOps {
            restores: restores.len() as u64,
            removes: removes.len() as u64,
            clears: clears.len() as u64,
            purged,
        })
    }
}
