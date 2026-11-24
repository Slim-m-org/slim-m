// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `canvas_audit_log`: one row per object a `remove`, `clear` or `restore`
//! actually touched, written in the same transaction as the op itself.
//!
//! This exists because `canvas_ops_sweep` starts deleting old `remove`,
//! `clear` and `restore` rows once nothing they touched is still unrestored -
//! see that module's doc comment for the retention rule - and
//! `http::canvas_ops::CanvasOpDto`'s own doc comment already named an
//! uncompacted op stream as what lets a moderator see who removed what.
//! Compaction breaks that unless the fact is kept somewhere else first, and
//! this table is that somewhere else. `place` is not logged: an object's
//! `author_id` already carries that durably on `canvas_objects`, which is
//! never swept.
//!
//! A member undoing or restoring their own ink is not logged: the object's
//! author already says whose it was, and logging it would let one member
//! grow the table without bound. The sweep ages the table out as well; see
//! `canvas_ops_sweep`.

use crate::ids::{CanvasObjectId, ChannelId, UserId};

/// Rows per `INSERT`: five bound values each stay far under SQLite's variable limit.
const AUDIT_ROWS_PER_INSERT: usize = 500;

/// Records one audit row per id in `object_ids`, for a `kind` of `"remove"`,
/// `"clear"` or `"restore"` only - the moderation acts, the same set
/// `http::canvas_ops`'s own actor-withholding check already singles out.
/// Called only from the fresh, effective path in `submit_canvas_op`; a
/// replay writes nothing here, the same reason it publishes nothing.
pub(in crate::store) async fn record_canvas_audit(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    actor_id: UserId,
    kind: &str,
    object_ids: &[CanvasObjectId],
    created_at: i64,
) -> Result<(), sqlx::Error> {
    if !matches!(kind, "remove" | "clear" | "restore") {
        return Ok(());
    }
    for chunk in object_ids.chunks(AUDIT_ROWS_PER_INSERT) {
        let others = not_authored_by(tx, actor_id, chunk).await?;
        if others.is_empty() {
            continue;
        }
        let mut builder = sqlx::QueryBuilder::new(
            "INSERT INTO canvas_audit_log (channel_id, object_id, actor_id, action, created_at) ",
        );
        builder.push_values(&others, |mut row, object_id| {
            row.push_bind(channel_id)
                .push_bind(*object_id)
                .push_bind(actor_id)
                .push_bind(kind)
                .push_bind(created_at);
        });
        builder.build().execute(&mut **tx).await?;
    }
    Ok(())
}

/// The ids of `ids` that `actor_id` did not author, which includes objects whose author is gone.
async fn not_authored_by(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    actor_id: UserId,
    ids: &[CanvasObjectId],
) -> Result<Vec<CanvasObjectId>, sqlx::Error> {
    let mut builder = sqlx::QueryBuilder::new("SELECT id FROM canvas_objects WHERE id IN (");
    let mut separated = builder.separated(", ");
    for id in ids {
        separated.push_bind(*id);
    }
    builder.push(") AND (author_id IS NULL OR author_id != ");
    builder.push_bind(actor_id);
    builder.push(")");
    builder.build_query_scalar().fetch_all(&mut **tx).await
}
