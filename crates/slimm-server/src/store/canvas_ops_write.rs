// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Submitting a mutation to the canvas op stream: `remove`, `clear`,
//! `restore`, `move`, and `reorder`.
//!
//! A sibling of [`super::canvas_ops`] rather than part of it, the same split
//! `http::canvas` and `http::canvas_write` already make: the read and write
//! halves of one surface stay under the review budget separately.
//!
//! Every branch here allocates one seq and writes one `canvas_ops` row in the
//! same transaction that applies the change, or it writes neither - the
//! property the whole op stream rests on. `restore` un-deletes exactly the
//! objects a named `remove` or `clear` op touched: for a `remove` that is its
//! own `canvas_op_targets` rows, and for a `clear` (which stores no per-object
//! targets, only a fence) it is every object whose `deleted_at` matches that
//! exact op's timestamp - unique by construction, see the sibling
//! `canvas_op_clock` module. `move` and `reorder` both reuse
//! `canvas_op_targets` too, one row naming the object each repositioned or
//! restacked, so a reconnecting client's catch-up feed learns of either the
//! same way it already learns of a remove - without it, a change made while
//! a viewer's pane was closed would never reach them, since neither a
//! coordinate nor a `z_index` update advances the object's own `seq` the way
//! `canvas_objects.seq` is fixed at placement.
//!
//! `reorder` carries an explicit target `z_index` rather than a relative
//! "bring to front"/"send to back" flag, the same choice `move` already makes
//! for bounds over a delta: the caller (client-side) computes the value
//! against whatever it currently knows, and last-write-wins on the stored
//! column is what makes two concurrent reorders resolve unambiguously,
//! whichever commits second landing strictly on top of - or below - the
//! other. It is also what makes undo exact: reversing a reorder is resubmitting
//! the object's own prior `z_index`, not a guess at some inverse action.
//!
//! This file is the orchestrator and the public request/result types only;
//! what each kind actually authorizes and touches is
//! `super::canvas_ops_apply`, split out once `move` joining `remove`, `clear`
//! and `restore` crossed the 500-line hard limit.

use super::canvas::next_canvas_seq;
use super::canvas_audit::record_canvas_audit;
use super::canvas_ops_apply::{
    affected_count_for, apply_move, apply_remove, apply_reorder, apply_restore, current_canvas_seq,
    fetch_op,
};
use super::{PlaceError, Store};
use crate::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};

/// How many `canvas_op_targets` rows one `INSERT` writes at a time. A
/// `restore` of a large `clear` can touch up to `MAX_OBJECTS_PER_CHANNEL`
/// (20,000) ids; batching this the same way `undelete_batch` batches the
/// un-delete itself is what keeps the second half of that write cheap too.
const TARGET_ROW_INSERT_BATCH: usize = 500;

/// Writes one `canvas_op_targets` row per id in `touched_ids`, batched rather
/// than one round trip per row - see [`TARGET_ROW_INSERT_BATCH`].
async fn insert_targets_batch(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    seq: i64,
    touched_ids: &[CanvasObjectId],
) -> Result<(), sqlx::Error> {
    for chunk in touched_ids.chunks(TARGET_ROW_INSERT_BATCH) {
        let mut builder =
            sqlx::QueryBuilder::new("INSERT INTO canvas_op_targets (channel_id, seq, object_id) ");
        builder.push_values(chunk, |mut row, object_id| {
            row.push_bind(channel_id)
                .push_bind(seq)
                .push_bind(*object_id);
        });
        builder.build().execute(&mut **tx).await?;
    }
    Ok(())
}

/// Most object ids one `remove` may name in a single op.
///
/// The event this produces has to fit the WebSocket's own 4 KiB frame ceiling:
/// 64 UUID strings with separators is roughly 2.5 KiB, leaving room for the
/// envelope, and the same bound caps a single request at 64 write-locked
/// point updates.
pub const MAX_REMOVE_IDS_PER_OP: usize = 64;

/// One canvas mutation submitted through `POST /channels/{id}/canvas/ops`.
pub enum CanvasOpRequest {
    Remove(Vec<CanvasObjectId>),
    Clear {
        before_seq: i64,
    },
    /// Un-deletes what a named `remove` or `clear` op touched.
    Restore {
        target_op: CanvasOpId,
    },
    /// Repositions one live object to a new bounding box, never touching its
    /// `z_index`. A resize is the same request with `w`/`h` changed: the
    /// server has no separate notion of "moved" versus "resized", since both
    /// are just a new box.
    Move {
        object_id: CanvasObjectId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
    /// Sets one live object's paint order to an explicit `z_index`, never
    /// touching its bounds. The caller computes the target value (typically
    /// one above or below every `z_index` it currently knows about, for
    /// "bring to front"/"send to back"); the server only applies and
    /// broadcasts it, the same explicit-value shape `Move` already uses for
    /// bounds rather than a server-computed delta.
    Reorder {
        object_id: CanvasObjectId,
        z_index: i64,
    },
}

/// The result of submitting one op, fresh or replayed.
pub struct SubmittedOp {
    pub id: CanvasOpId,
    pub seq: i64,
    pub kind: String,
    pub affected: i64,
    pub created_at: i64,
    /// Whether this call is what wrote the stored op, the same meaning
    /// [`super::canvas::Placement::fresh`] carries.
    pub fresh: bool,
    /// The ids a fresh `remove`, `clear` or `restore` actually touched - a
    /// subset of what was named (or, for `clear`, of what the fence covered),
    /// since an id already in its target state is not touched again. Also
    /// what [`Store::record_canvas_audit`] writes one row per, for `remove`,
    /// `clear` and `restore`. Empty for a replay, which never publishes and
    /// so never needs this.
    pub touched_ids: Vec<CanvasObjectId>,
    /// The fence a fresh `clear` applied, carried separately from
    /// `touched_ids` for the live event, which names the fence rather than
    /// enumerating potentially many ids. `None` for `remove`, `restore`, and
    /// a replay.
    pub cleared_before_seq: Option<i64>,
    /// The bounds a fresh `move` applied, for the live event to carry so a
    /// receiver need not refetch. `None` for every other kind and for a
    /// replay, for the same reason `touched_ids` is empty there.
    pub moved_to: Option<(f64, f64, f64, f64)>,
    /// The `z_index` a fresh `reorder` applied, for the same reason
    /// `moved_to` exists. `None` for every other kind and for a replay.
    pub reordered_to: Option<i64>,
}

/// Why submitting an op failed.
#[derive(Debug)]
pub enum SubmitOpError {
    /// An id named in the request does not resolve inside this channel -
    /// absent entirely, or belonging to another one; or a restore's
    /// `target_op` names an op that is not a `remove` or `clear` in this
    /// channel. One answer for all three, so the route is not a
    /// deployment-wide existence oracle.
    NotFound,
    /// Removing another member's object, clearing, or restoring an op you did
    /// not author, without `MANAGE_CANVAS`.
    NotAuthorized,
    /// A restore would push this channel's live object count past
    /// [`MAX_OBJECTS_PER_CHANNEL`].
    ChannelFull,
    /// A `move`'s target bounds are not finite, have negative extent, exceed
    /// `MAX_OBJECT_EXTENT`, or fall outside the bounded world - the same
    /// check a placement itself makes.
    OutOfBounds,
    /// A `move` or `reorder` naming an object locked in place.
    Locked,
    Internal(anyhow::Error),
}

impl From<PlaceError> for SubmitOpError {
    fn from(err: PlaceError) -> Self {
        match err {
            PlaceError::OutOfBounds => SubmitOpError::OutOfBounds,
            // `move_canvas_object_query` only ever returns these two variants.
            other => SubmitOpError::Internal(anyhow::anyhow!("unexpected move error: {other:?}")),
        }
    }
}

impl From<sqlx::Error> for SubmitOpError {
    fn from(err: sqlx::Error) -> Self {
        SubmitOpError::Internal(err.into())
    }
}

impl From<anyhow::Error> for SubmitOpError {
    fn from(err: anyhow::Error) -> Self {
        SubmitOpError::Internal(err)
    }
}

impl Store {
    /// Submits a `remove`, `clear`, `restore`, `move` or `reorder`,
    /// idempotent by `op_id` the way placing an object is idempotent by the
    /// object's own id.
    ///
    /// `may_moderate` is the caller's already-evaluated `MANAGE_CANVAS`,
    /// resolved once by the caller alongside `VIEW_CHANNEL`/`USE_CANVAS`
    /// rather than re-read here.
    ///
    /// Every kind but `clear` writes one `canvas_op_targets` row per touched
    /// id, both for `restore_candidates`'s own `remove` lookup and for
    /// `list_canvas_ops`'s page-byte budget, which prices those rows as that
    /// kind's own wire payload. A `clear` is a fence over `before_seq`, never
    /// a list - `restore_candidates`'s `clear` branch reads the
    /// `deleted_at` fence, not this table, and `CanvasOpBodyDto::Clear` never
    /// serializes an object list either - so a row written here for it would
    /// be dead weight with one live cost: pricing a `clear` as if it carried
    /// an `object_ids` array its own DTO never has.
    pub async fn submit_canvas_op(
        &self,
        channel_id: ChannelId,
        actor_id: UserId,
        op_id: CanvasOpId,
        may_moderate: bool,
        request: CanvasOpRequest,
    ) -> Result<SubmittedOp, SubmitOpError> {
        let mut tx = self.begin_write().await?;

        if let Some(existing) = fetch_op(&mut tx, op_id).await? {
            if existing.channel_id != channel_id {
                tx.commit().await?;
                return Err(SubmitOpError::NotFound);
            }
            let affected = affected_count_for(&mut tx, channel_id, &existing).await?;
            tx.commit().await?;
            return Ok(SubmittedOp {
                id: op_id,
                seq: existing.seq,
                kind: existing.kind,
                affected,
                created_at: existing.created_at,
                fresh: false,
                touched_ids: Vec::new(),
                cleared_before_seq: None,
                moved_to: None,
                reordered_to: None,
            });
        }

        // Unique, not just `now_ms()`; see `now_ms_unique`'s own doc.
        let now = self.now_ms_unique(&mut tx).await?;
        // Only a `restore` sets this; `canvas_op_target` requires exactly that.
        let mut target_op_for_row: Option<CanvasOpId> = None;
        // Only a fresh, effective `move` sets this.
        let mut move_bounds: Option<(f64, f64, f64, f64)> = None;
        // Only a fresh, effective `reorder` sets this.
        let mut reorder_z: Option<i64> = None;
        let (kind, affected, touched_ids, bound_seq) = match request {
            CanvasOpRequest::Remove(object_ids) => {
                apply_remove(
                    &mut tx,
                    channel_id,
                    actor_id,
                    may_moderate,
                    &object_ids,
                    now,
                )
                .await?
            }
            CanvasOpRequest::Clear { before_seq } => {
                if !may_moderate {
                    tx.commit().await?;
                    return Err(SubmitOpError::NotAuthorized);
                }
                // RETURNING rather than rows_affected(): the audit log below needs the ids.
                let touched: Vec<CanvasObjectId> = sqlx::query_scalar!(
                    r#"UPDATE canvas_objects SET deleted_at = ?
                       WHERE channel_id = ? AND deleted_at IS NULL AND seq <= ?
                       RETURNING id AS "id!: CanvasObjectId""#,
                    now,
                    channel_id,
                    before_seq
                )
                .fetch_all(&mut *tx)
                .await?;
                let affected = touched.len() as i64;
                ("clear", affected, touched, Some(before_seq))
            }
            CanvasOpRequest::Restore { target_op } => {
                target_op_for_row = Some(target_op);
                apply_restore(&mut tx, channel_id, actor_id, may_moderate, target_op).await?
            }
            CanvasOpRequest::Move {
                object_id,
                x,
                y,
                w,
                h,
            } => {
                let outcome = apply_move(
                    &mut tx,
                    channel_id,
                    actor_id,
                    may_moderate,
                    object_id,
                    (x, y, w, h),
                )
                .await?;
                if outcome.1 > 0 {
                    move_bounds = Some((x, y, w, h));
                }
                outcome
            }
            CanvasOpRequest::Reorder { object_id, z_index } => {
                let outcome = apply_reorder(
                    &mut tx,
                    channel_id,
                    actor_id,
                    may_moderate,
                    object_id,
                    z_index,
                )
                .await?;
                if outcome.1 > 0 {
                    reorder_z = Some(z_index);
                }
                outcome
            }
        };

        // An op row exists only for a real state transition; see the module doc.
        if affected == 0 {
            let seq = current_canvas_seq(&mut tx, channel_id).await?;
            tx.commit().await?;
            return Ok(SubmittedOp {
                id: op_id,
                seq,
                kind: kind.to_owned(),
                affected: 0,
                created_at: now,
                fresh: true,
                touched_ids: Vec::new(),
                cleared_before_seq: None,
                moved_to: None,
                reordered_to: None,
            });
        }

        let seq = next_canvas_seq(&mut tx, channel_id).await?;

        let (move_x, move_y, move_w, move_h) = match move_bounds {
            Some((x, y, w, h)) => (Some(x), Some(y), Some(w), Some(h)),
            None => (None, None, None, None),
        };
        sqlx::query!(
            r#"INSERT INTO canvas_ops
                   (channel_id, seq, id, kind, actor_id, bound_seq, target_op,
                    move_x, move_y, move_w, move_h, reorder_z, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"#,
            channel_id,
            seq,
            op_id,
            kind,
            actor_id,
            bound_seq,
            target_op_for_row,
            move_x,
            move_y,
            move_w,
            move_h,
            reorder_z,
            now
        )
        .execute(&mut *tx)
        .await?;

        // A `clear` names no per-object row here; see this function's own doc.
        if kind != "clear" {
            insert_targets_batch(&mut tx, channel_id, seq, &touched_ids).await?;
        }
        record_canvas_audit(&mut tx, channel_id, actor_id, kind, &touched_ids, now).await?;

        tx.commit().await?;

        Ok(SubmittedOp {
            id: op_id,
            seq,
            kind: kind.to_owned(),
            affected,
            created_at: now,
            fresh: true,
            touched_ids,
            cleared_before_seq: bound_seq,
            moved_to: move_bounds,
            reordered_to: reorder_z,
        })
    }
}
