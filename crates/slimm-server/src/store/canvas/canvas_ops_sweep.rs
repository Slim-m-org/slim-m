// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Compacting `canvas_ops`: reclaiming `remove`, `clear` and `restore` rows
//! once nothing they did is still in effect (and `edit` rows once a later edit
//! of the same object supersedes them), on the same periodic-sweep
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
//! Each pass walks its rows with a keyset cursor within one tick, so a row that
//! is not yet eligible is looked at once, not once per batch.
//!
//! Past the space's message retention window, erased objects are removed for
//! good as well; see `canvas_purge`.

use super::super::{Store, now_ms};
use crate::ids::ChannelId;

/// Roughly the roadmap's own number for the op log.
pub const CANVAS_OP_RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// How long `canvas_audit_log` keeps a moderation row; longer than the op log it backstops.
pub const CANVAS_AUDIT_RETENTION_MS: i64 = 365 * 24 * 60 * 60 * 1000;

/// Bounds how long one batch can hold the write lock, the same reasoning
/// `ORPHAN_SWEEP_BATCH` documents for the attachment sweep.
const CANVAS_OP_SWEEP_BATCH: i64 = 500;
/// How many batches one tick may run, each in its own transaction so writers get the lock between them.
const CANVAS_OP_BATCHES_PER_TICK: usize = 50;

/// How many rows one sweep pass reclaimed, by kind.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct SweptCanvasOps {
    pub restores: u64,
    pub removes: u64,
    pub clears: u64,
    /// Superseded `edit` rows, kept only as the latest per object.
    pub edits: u64,
    /// Moderation audit rows past [`CANVAS_AUDIT_RETENTION_MS`].
    pub audit: u64,
    /// Erased objects removed for good once past message retention.
    pub purged: u64,
}

impl SweptCanvasOps {
    pub fn total(&self) -> u64 {
        self.restores + self.removes + self.clears + self.edits + self.audit + self.purged
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

/// Where a pass stopped: the sort key of the last row it examined.
#[derive(Clone, Copy)]
struct Cursor {
    created_at: i64,
    channel_id: ChannelId,
    seq: i64,
}

impl Cursor {
    const START: Cursor = Cursor {
        created_at: -1,
        channel_id: ChannelId(uuid::Uuid::nil()),
        seq: 0,
    };

    fn after(self, rows: &[(i64, ChannelId, i64)]) -> Cursor {
        rows.iter()
            .map(|&(created_at, channel_id, seq)| Cursor {
                created_at,
                channel_id,
                seq,
            })
            .max_by_key(|c| (c.created_at, c.channel_id.0, c.seq))
            .unwrap_or(self)
    }
}

/// One pass's cursor, and whether it has run out of rows.
#[derive(Clone, Copy)]
struct Pass {
    cursor: Cursor,
    done: bool,
}

impl Pass {
    const START: Pass = Pass {
        cursor: Cursor::START,
        done: false,
    };

    fn advance(&mut self, rows: &[(i64, ChannelId, i64)]) {
        self.cursor = self.cursor.after(rows);
        self.done = (rows.len() as i64) < CANVAS_OP_SWEEP_BATCH;
    }
}

struct Passes {
    restores: Pass,
    removes: Pass,
    clears: Pass,
    edits: Pass,
}

impl Passes {
    fn finished(&self) -> bool {
        self.restores.done && self.removes.done && self.clears.done && self.edits.done
    }
}

impl Store {
    /// Deletes canvas ops old enough, and no longer needed to undo anything,
    /// across every channel, a batch at a time until every pass runs dry or
    /// [`CANVAS_OP_BATCHES_PER_TICK`] is reached. See the module doc for the
    /// retention rule.
    pub async fn sweep_canvas_ops(&self) -> anyhow::Result<SweptCanvasOps> {
        let now = now_ms();
        let cutoff = now - CANVAS_OP_RETENTION_MS;
        let mut swept = SweptCanvasOps::default();
        let mut passes = Passes {
            restores: Pass::START,
            removes: Pass::START,
            clears: Pass::START,
            edits: Pass::START,
        };
        for _ in 0..CANVAS_OP_BATCHES_PER_TICK {
            let batch = self.sweep_canvas_op_batch(cutoff, &mut passes).await?;
            swept.restores += batch.restores;
            swept.removes += batch.removes;
            swept.clears += batch.clears;
            swept.edits += batch.edits;
            if passes.finished() {
                break;
            }
        }
        swept.audit = self
            .sweep_canvas_audit(now - CANVAS_AUDIT_RETENTION_MS)
            .await?;
        swept.purged = self.purge_erased_canvas_objects().await?;
        Ok(swept)
    }

    /// Deletes audit rows older than `cutoff`, oldest first so the scan stops at the first young row.
    async fn sweep_canvas_audit(&self, cutoff: i64) -> anyhow::Result<u64> {
        let mut total = 0u64;
        for _ in 0..CANVAS_OP_BATCHES_PER_TICK {
            let mut tx = self.begin_write().await?;
            let gone = sqlx::query!(
                "DELETE FROM canvas_audit_log WHERE id IN (
                     SELECT id FROM canvas_audit_log WHERE created_at < ? ORDER BY id LIMIT ?
                 )",
                cutoff,
                CANVAS_OP_SWEEP_BATCH
            )
            .execute(&mut *tx)
            .await?
            .rows_affected();
            tx.commit().await?;
            total += gone;
            if gone < CANVAS_OP_SWEEP_BATCH as u64 {
                break;
            }
        }
        Ok(total)
    }

    /// One transaction of at most [`CANVAS_OP_SWEEP_BATCH`] rows per kind.
    async fn sweep_canvas_op_batch(
        &self,
        cutoff: i64,
        passes: &mut Passes,
    ) -> anyhow::Result<SweptCanvasOps> {
        let mut tx = self.begin_write().await?;

        // Pass 1: restores, gated on age alone, unless a clear separates them from their remove.
        let restores = if passes.restores.done {
            Vec::new()
        } else {
            let at = passes.restores.cursor;
            sqlx::query!(
                r#"DELETE FROM canvas_ops WHERE id IN (
                   SELECT o.id FROM canvas_ops o
                   WHERE o.kind = 'restore' AND o.created_at < ?1
                     AND (o.created_at, o.channel_id, o.seq) > (?3, ?4, ?5)
                     AND NOT EXISTS (
                         SELECT 1 FROM canvas_ops t
                         JOIN canvas_ops c ON c.channel_id = t.channel_id AND c.kind = 'clear'
                           AND c.seq > t.seq AND c.seq < o.seq
                         WHERE t.id = o.target_op
                     )
                   ORDER BY o.created_at, o.channel_id, o.seq
                   LIMIT ?2
               )
               RETURNING created_at AS "created_at!: i64", channel_id AS "channel_id!: ChannelId", seq AS "seq!: i64""#,
                cutoff,
                CANVAS_OP_SWEEP_BATCH,
                at.created_at,
                at.channel_id,
                at.seq
            )
            .fetch_all(&mut *tx)
            .await?
            .into_iter()
            .map(|row| (row.created_at, row.channel_id, row.seq))
            .collect()
        };
        passes.restores.advance(&restores);

        // Pass 2a: removes, guarded by the same exact-timestamp fence `apply_restore` checks.
        let removes = if passes.removes.done {
            Vec::new()
        } else {
            let at = passes.removes.cursor;
            sqlx::query!(
                r#"DELETE FROM canvas_ops WHERE id IN (
                   SELECT o.id FROM canvas_ops o
                   WHERE o.kind = 'remove'
                     AND o.created_at < ?1
                     AND (o.created_at, o.channel_id, o.seq) > (?3, ?4, ?5)
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
                   ORDER BY o.created_at, o.channel_id, o.seq
                   LIMIT ?2
               )
               RETURNING created_at AS "created_at!: i64", channel_id AS "channel_id!: ChannelId", seq AS "seq!: i64""#,
                cutoff,
                CANVAS_OP_SWEEP_BATCH,
                at.created_at,
                at.channel_id,
                at.seq
            )
            .fetch_all(&mut *tx)
            .await?
            .into_iter()
            .map(|row| (row.created_at, row.channel_id, row.seq))
            .collect()
        };
        passes.removes.advance(&removes);

        // Pass 2b: clears, guarded by the exact-timestamp fence restore_candidates uses.
        let clears = if passes.clears.done {
            Vec::new()
        } else {
            let at = passes.clears.cursor;
            sqlx::query!(
                r#"DELETE FROM canvas_ops WHERE id IN (
                   SELECT o.id FROM canvas_ops o
                   WHERE o.kind = 'clear'
                     AND o.created_at < ?1
                     AND (o.created_at, o.channel_id, o.seq) > (?3, ?4, ?5)
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
                   ORDER BY o.created_at, o.channel_id, o.seq
                   LIMIT ?2
               )
               RETURNING created_at AS "created_at!: i64", channel_id AS "channel_id!: ChannelId", seq AS "seq!: i64""#,
                cutoff,
                CANVAS_OP_SWEEP_BATCH,
                at.created_at,
                at.channel_id,
                at.seq
            )
            .fetch_all(&mut *tx)
            .await?
            .into_iter()
            .map(|row| (row.created_at, row.channel_id, row.seq))
            .collect()
        };
        passes.clears.advance(&clears);

        // Pass 2c: an edit a later edit of the same object supersedes; the object's props already hold the latest.
        let edits = if passes.edits.done {
            Vec::new()
        } else {
            let at = passes.edits.cursor;
            sqlx::query!(
                r#"DELETE FROM canvas_ops WHERE id IN (
                   SELECT o.id FROM canvas_ops o
                   WHERE o.kind = 'edit'
                     AND o.created_at < ?1
                     AND (o.created_at, o.channel_id, o.seq) > (?3, ?4, ?5)
                     AND EXISTS (
                         SELECT 1 FROM canvas_op_targets t
                         JOIN canvas_op_targets later
                           ON later.channel_id = t.channel_id AND later.object_id = t.object_id
                          AND later.seq > t.seq
                         JOIN canvas_ops edit
                           ON edit.channel_id = later.channel_id AND edit.seq = later.seq
                          AND edit.kind = 'edit'
                         WHERE t.channel_id = o.channel_id AND t.seq = o.seq
                     )
                   ORDER BY o.created_at, o.channel_id, o.seq
                   LIMIT ?2
               )
               RETURNING created_at AS "created_at!: i64", channel_id AS "channel_id!: ChannelId", seq AS "seq!: i64""#,
                cutoff,
                CANVAS_OP_SWEEP_BATCH,
                at.created_at,
                at.channel_id,
                at.seq
            )
            .fetch_all(&mut *tx)
            .await?
            .into_iter()
            .map(|row| (row.created_at, row.channel_id, row.seq))
            .collect()
        };
        passes.edits.advance(&edits);

        let swept: Vec<(ChannelId, i64)> = [&restores, &removes, &clears, &edits]
            .into_iter()
            .flatten()
            .map(|&(_, channel_id, seq)| (channel_id, seq))
            .collect();
        raise_swept_watermark(&mut tx, &swept).await?;
        tx.commit().await?;

        Ok(SweptCanvasOps {
            restores: restores.len() as u64,
            removes: removes.len() as u64,
            clears: clears.len() as u64,
            edits: edits.len() as u64,
            audit: 0,
            purged: 0,
        })
    }
}
