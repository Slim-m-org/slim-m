// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A note's, text box's or edge's props changed after placement (decision 0072), authorized like a
//! move: your own object needs nothing more, anyone else's needs `MANAGE_CANVAS`,
//! and a locked object stays as it is. A note or text box is replaced wholesale; an edge merges
//! (decision 0137).

use super::canvas_edges::{EdgeError, resolve_edge, set_hull, write_ends};
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
    written: &mut Option<String>,
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
        "note" | "edge" => {}
        "text" => check_text(props)?,
        _ => return Err(SubmitOpError::NotEditable),
    }
    if !locked_among(tx, &[object_id]).await?.is_empty() {
        return Err(SubmitOpError::Locked);
    }
    if found.deleted_at.is_some() {
        return Ok(("edit", 0, Vec::new(), None));
    }
    let next = if found.kind == "edge" {
        let stored: serde_json::Value = serde_json::from_str(&found.props)
            .map_err(|_| SubmitOpError::BadProps("canvas props must be an object"))?;
        let edit: serde_json::Value = serde_json::from_str(props)
            .map_err(|_| SubmitOpError::BadProps("canvas props must be an object"))?;
        let merged = crate::canvas_edge::merge_edge_props(&stored, &edit);
        if merged == stored {
            return Ok(("edit", 0, Vec::new(), None));
        }
        write_edge(tx, channel_id, object_id, &merged).await?
    } else if found.props == props {
        return Ok(("edit", 0, Vec::new(), None));
    } else {
        props.to_owned()
    };
    sqlx::query!(
        "UPDATE canvas_object_props SET props = ? WHERE object_id = ?",
        next,
        object_id
    )
    .execute(&mut **tx)
    .await?;
    *written = Some(next);
    Ok(("edit", 1, vec![object_id], None))
}

/// Validates merged edge props, re-resolves its ends and rewrites the end rows and the hull;
/// returns the props to store.
async fn write_edge(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    edge_id: CanvasObjectId,
    merged: &serde_json::Value,
) -> Result<String, SubmitOpError> {
    crate::canvas_edge::check_edge_props(merged).map_err(SubmitOpError::BadProps)?;
    let text = serde_json::to_string(merged)
        .map_err(|_| SubmitOpError::BadProps("canvas props must be an object"))?;
    if text.len() > crate::canvas_text::MAX_PROPS_BYTES {
        return Err(SubmitOpError::BadProps("canvas props are too large"));
    }
    let resolved = resolve_edge(tx, channel_id, edge_id, merged)
        .await
        .map_err(|err| match err {
            EdgeError::EndMissing => SubmitOpError::NotFound,
            EdgeError::EndNotAttachable => {
                SubmitOpError::BadProps("a connection cannot attach to that kind of object")
            }
            EdgeError::TooManyEdges => SubmitOpError::EdgeLimit,
            EdgeError::Db(err) => err.into(),
        })?;
    write_ends(tx, edge_id, &resolved).await?;
    set_hull(tx, edge_id, resolved.hull).await?;
    Ok(text)
}
