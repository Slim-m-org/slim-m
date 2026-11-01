// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A note's or text box's props replaced after placement (decision 0072), authorized like a
//! move: your own note needs nothing more, anyone else's needs `MANAGE_CANVAS`,
//! and a locked note stays as it is.

use super::canvas_object_locks::locked_among;
use super::canvas_ops_write::SubmitOpError;
use crate::ids::{CanvasObjectId, ChannelId, UserId};

fn check_text(props: &str) -> Result<(), SubmitOpError> {
    let value = serde_json::from_str(props)
        .map_err(|_| SubmitOpError::BadProps("canvas props must be an object"))?;
    crate::canvas_text::check_text_props(&value).map_err(SubmitOpError::BadProps)
}

pub(in crate::store) async fn apply_edit(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    actor_id: UserId,
    may_moderate: bool,
    object_id: CanvasObjectId,
    props: &str,
) -> Result<(&'static str, i64, Vec<CanvasObjectId>, Option<i64>), SubmitOpError> {
    let Some(found) = sqlx::query!(
        r#"SELECT o.author_id AS "author_id: UserId", o.kind AS "kind!",
                  o.deleted_at AS "deleted_at: i64", p.props AS "props!"
           FROM canvas_objects o JOIN canvas_object_props p ON p.object_id = o.id
           WHERE o.id = ? AND o.channel_id = ?"#,
        object_id,
        channel_id
    )
    .fetch_optional(&mut **tx)
    .await?
    else {
        return Err(SubmitOpError::NotFound);
    };
    if !may_moderate && found.author_id != Some(actor_id) {
        return Err(SubmitOpError::NotAuthorized);
    }
    match found.kind.as_str() {
        "note" => {}
        "text" => check_text(props)?,
        _ => return Err(SubmitOpError::NotEditable),
    }
    if !locked_among(tx, &[object_id]).await?.is_empty() {
        return Err(SubmitOpError::Locked);
    }
    if found.deleted_at.is_some() || found.props == props {
        return Ok(("edit", 0, Vec::new(), None));
    }
    sqlx::query!(
        "UPDATE canvas_object_props SET props = ? WHERE object_id = ?",
        props,
        object_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(("edit", 1, vec![object_id], None))
}
