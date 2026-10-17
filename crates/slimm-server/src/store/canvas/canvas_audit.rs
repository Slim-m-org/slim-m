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

use crate::ids::{CanvasObjectId, ChannelId, UserId};

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
    for object_id in object_ids {
        sqlx::query!(
            r#"INSERT INTO canvas_audit_log (channel_id, object_id, actor_id, action, created_at)
               VALUES (?, ?, ?, ?, ?)"#,
            channel_id,
            object_id,
            actor_id,
            kind,
            created_at
        )
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}
