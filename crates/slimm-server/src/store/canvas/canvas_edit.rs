// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A note's, text box's, edge's, shape's or image's props changed after placement (decision 0072),
//! authorized like a move: your own object needs nothing more, anyone else's needs
//! `MANAGE_CANVAS`, and a locked object stays as it is. A text box is replaced wholesale; the
//! rest merge (decision 0137).

use super::canvas_edges::{EdgeError, resolve_edge, set_hull, write_ends};
use super::canvas_object_locks::locked_among;
use super::canvas_ops_write::SubmitOpError;
use serde_json::Value;

use crate::ids::{CanvasObjectId, ChannelId, UserId};

fn parse(props: &str) -> Result<Value, SubmitOpError> {
    serde_json::from_str(props)
        .map_err(|_| SubmitOpError::BadProps("canvas props must be an object"))
}

/// A text box is replaced wholesale, so its props are what the edit says.
fn edit_text(_stored: &str, props: &str) -> Result<String, SubmitOpError> {
    crate::canvas_text::check_text_props(&parse(props)?).map_err(SubmitOpError::BadProps)?;
    Ok(props.to_owned())
}

/// The edit laid over what is stored, so a client that knows fewer props leaves the rest alone.
fn merge_edit(stored: &str, edit: &Value) -> Result<String, SubmitOpError> {
    let merged = crate::canvas_text::merge_props(&parse(stored)?, edit);
    let merged = serde_json::to_string(&merged)
        .map_err(|_| SubmitOpError::BadProps("canvas props must be an object"))?;
    if merged.len() > crate::canvas_text::MAX_PROPS_BYTES {
        return Err(SubmitOpError::BadProps("canvas props are too large"));
    }
    Ok(merged)
}

fn edit_note(stored: &str, props: &str) -> Result<String, SubmitOpError> {
    let edit = parse(props)?;
    crate::canvas_text::check_note_props(&edit).map_err(SubmitOpError::BadProps)?;
    merge_edit(stored, &edit)
}

/// A shape's props are opaque at placement too, so an edit only has to stay an object under the size cap.
fn edit_shape(stored: &str, props: &str) -> Result<String, SubmitOpError> {
    merge_edit(stored, &parse(props)?)
}

/// An image keeps the attachment it was placed with, since that reference passed the upload ownership check.
fn edit_image(stored: &str, props: &str) -> Result<String, SubmitOpError> {
    let edit = parse(props)?;
    if let Some(attachment) = edit.get("attachment")
        && parse(stored)?.get("attachment") != Some(attachment)
    {
        return Err(SubmitOpError::BadProps(
            "an image's attachment cannot be edited",
        ));
    }
    merge_edit(stored, &edit)
}

/// The op outcome and, when something changed, the props now stored.
pub(in crate::store) struct EditOutcome {
    pub(in crate::store) outcome: (&'static str, i64, Vec<CanvasObjectId>, Option<i64>),
    pub(in crate::store) props: Option<String>,
}

/// An edge merges over what it stores, like a note; its ends are re-resolved once the edit is known to change it.
fn edit_edge(stored: &str, props: &str) -> Result<String, SubmitOpError> {
    let merged = crate::canvas_edge::merge_edge_props(&parse(stored)?, &parse(props)?);
    serde_json::to_string(&merged)
        .map_err(|_| SubmitOpError::BadProps("canvas props must be an object"))
}

pub(in crate::store) async fn apply_edit(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    actor_id: UserId,
    may_moderate: bool,
    object_id: CanvasObjectId,
    props: &str,
) -> Result<EditOutcome, SubmitOpError> {
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
    let mut next = match found.kind.as_str() {
        "note" => edit_note(&found.props, props)?,
        "text" => edit_text(&found.props, props)?,
        "edge" => edit_edge(&found.props, props)?,
        "shape" => edit_shape(&found.props, props)?,
        "image" => edit_image(&found.props, props)?,
        _ => return Err(SubmitOpError::NotEditable),
    };
    if !locked_among(tx, &[object_id]).await?.is_empty() {
        return Err(SubmitOpError::Locked);
    }
    let unchanged = match (parse(&found.props), parse(&next)) {
        (Ok(stored), Ok(next)) => stored == next,
        _ => found.props == next,
    };
    if found.deleted_at.is_some() || unchanged {
        return Ok(EditOutcome {
            outcome: ("edit", 0, Vec::new(), None),
            props: None,
        });
    }
    if found.kind == "edge" {
        next = write_edge(
            tx,
            channel_id,
            object_id,
            (&parse(&found.props)?, &parse(&next)?),
        )
        .await?;
    }
    sqlx::query!(
        "UPDATE canvas_object_props SET props = ? WHERE object_id = ?",
        next,
        object_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(EditOutcome {
        outcome: ("edit", 1, vec![object_id], None),
        props: Some(next),
    })
}

/// Validates merged edge props, re-resolves its ends and rewrites the end rows and the hull;
/// returns the props to store.
async fn write_edge(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    edge_id: CanvasObjectId,
    (stored, merged): (&serde_json::Value, &serde_json::Value),
) -> Result<String, SubmitOpError> {
    crate::canvas_edge::check_edge_props(merged).map_err(SubmitOpError::BadProps)?;
    crate::canvas_edge::check_ends_on_board(merged, Some(stored))
        .map_err(SubmitOpError::BadProps)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_note_stored_with_a_bad_key_can_still_be_edited() {
        let stored = r#"{"text":"old","size":"huge","color":3}"#;
        let merged = edit_note(stored, r#"{"text":"new"}"#).expect("the edit is valid");
        assert!(merged.contains(r#""text":"new""#));
    }

    #[test]
    fn an_edit_with_a_bad_key_is_refused() {
        assert!(edit_note(r#"{"text":"old"}"#, r#"{"size":"huge"}"#).is_err());
    }
}
