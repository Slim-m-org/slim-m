// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a `clear` removes: every unlocked object under its fence and scope.
//! A clear that finds nothing unlocked takes the locked ones too, so a second
//! clear (decision 0085) is the way to empty a board with pinned items.

use super::canvas_audit::record_canvas_audit;
use super::canvas_edges::{cascade_after_clear, record_cascades};
use super::canvas_ops_apply::current_canvas_seq;
use super::canvas_ops_write::{ClearScope, SubmitOpError, SubmittedOp, insert_targets_batch};
use super::next_canvas_seq;
use crate::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};

/// The objects a clear soft-deleted, and the locked ones it left standing.
pub(in crate::store) struct ClearOutcome {
    pub(in crate::store) cleared: Vec<CanvasObjectId>,
    pub(in crate::store) spared: Vec<CanvasObjectId>,
    /// Newer edges that lost an end to the sweep and fell with it; an undo revives them.
    pub(in crate::store) cascaded: Vec<CanvasObjectId>,
}

/// `spare_locks` false takes the locked objects in the first pass, for a board nobody can see.
pub(in crate::store) async fn apply_clear(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    before_seq: i64,
    scope: &ClearScope,
    now: i64,
    spare_locks: bool,
) -> Result<ClearOutcome, sqlx::Error> {
    let cleared = clear_matching(tx, channel_id, before_seq, scope, now, spare_locks).await?;
    if cleared.is_empty() {
        let cleared = clear_matching(tx, channel_id, before_seq, scope, now, false).await?;
        let cascaded = cascade_after_clear(tx, channel_id, now).await?;
        return Ok(ClearOutcome {
            cleared,
            spared: Vec::new(),
            cascaded,
        });
    }
    let cascaded = cascade_after_clear(tx, channel_id, now).await?;
    let mut spared = locked_matching(tx, channel_id, before_seq, scope).await?;
    spared.retain(|id| !cascaded.contains(id));
    Ok(ClearOutcome {
        cleared,
        spared,
        cascaded,
    })
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

/// What [`clear_in_tx`] needs; `now` is the op's unique timestamp, which a restore matches on.
pub(in crate::store) struct ClearInTx<'a> {
    pub channel_id: ChannelId,
    pub actor_id: UserId,
    pub op_id: CanvasOpId,
    pub before_seq: i64,
    pub scope: &'a ClearScope,
    /// False takes locked objects too, for a board nobody can see (decision 0139).
    pub spare_locks: bool,
    pub now: i64,
}

/// Runs a clear inside the caller's write transaction: the sweep, its op row, its target rows, edge cascades and audit rows.
///
/// The caller publishes `Cleared` after its own commit. An effect-free clear writes no op row, as every other kind does.
pub(in crate::store) async fn clear_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    params: ClearInTx<'_>,
) -> Result<SubmittedOp, SubmitOpError> {
    let ClearInTx {
        channel_id,
        actor_id,
        op_id,
        before_seq,
        scope,
        spare_locks,
        now,
    } = params;
    let outcome = apply_clear(tx, channel_id, before_seq, scope, now, spare_locks).await?;
    let touched_ids = outcome.cleared;
    let affected = touched_ids.len() as i64;
    if affected == 0 {
        let seq = current_canvas_seq(tx, channel_id).await?;
        return Ok(SubmittedOp {
            id: op_id,
            seq,
            kind: "clear".to_owned(),
            affected: 0,
            created_at: now,
            fresh: true,
            touched_ids: Vec::new(),
            cleared_before_seq: None,
            cleared_scope: None,
            spared_ids: Vec::new(),
            moved_to: None,
            reordered_to: None,
            edited_props: None,
        });
    }
    let seq = next_canvas_seq(tx, channel_id).await?;
    let clear_kinds = scope.kinds_json();
    sqlx::query!(
        r#"INSERT INTO canvas_ops
               (channel_id, seq, id, kind, actor_id, bound_seq, clear_kinds,
                clear_author_id, affected, created_at)
           VALUES (?, ?, ?, 'clear', ?, ?, ?, ?, ?, ?)"#,
        channel_id,
        seq,
        op_id,
        actor_id,
        before_seq,
        clear_kinds,
        scope.author_id,
        affected,
        now
    )
    .execute(&mut **tx)
    .await?;
    // A clear's target rows name the locked objects it spared, so a replay keeps them.
    insert_targets_batch(tx, channel_id, seq, &outcome.spared).await?;
    record_cascades(tx, channel_id, seq, &outcome.cascaded).await?;
    record_canvas_audit(tx, channel_id, actor_id, "clear", &touched_ids, now).await?;
    Ok(SubmittedOp {
        id: op_id,
        seq,
        kind: "clear".to_owned(),
        affected,
        created_at: now,
        fresh: true,
        touched_ids,
        cleared_before_seq: Some(before_seq),
        cleared_scope: Some(scope.clone()),
        spared_ids: outcome.spared,
        moved_to: None,
        reordered_to: None,
        edited_props: None,
    })
}
