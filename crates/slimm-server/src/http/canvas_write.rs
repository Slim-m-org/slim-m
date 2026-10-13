// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Placing one object on a channel's canvas.
//!
//! A sibling of [`super::canvas`] rather than part of it, so neither file
//! carries both halves of the surface past the review budget.
//!
//! This is the first caller of the direct timeout check `store::timeouts`
//! promised. `TIMEOUT_DENY` deliberately spares `USE_CANVAS`, because that one
//! bit means view *and* draw and subtracting it would blank the canvas rather
//! than make it read-only, so the write path asks about the timeout itself. A
//! timed-out member keeps seeing the canvas and cannot add to it, which is the
//! behaviour the bit cannot express.
//!
//! Three ceilings apply and each bounds a different thing: `MAX_PROPS_BYTES`
//! bounds one object, [`crate::store::MAX_OBJECT_EXTENT`] bounds the area one
//! object claims, and [`crate::store::MAX_OBJECTS_PER_CHANNEL`] bounds the
//! canvas.
//!
//! [`PlaceError::Removed`] exists because `super::canvas_ops_write` gave this
//! surface a removal path: replaying the id of an object a moderator erased
//! is now a distinct 409 from `IdConflict`, since an honest retry racing an
//! erase deserves a truthful answer, not "id taken".
//!
//! What the server does not validate is the inside of `props`, with one
//! exception: an `image` object's `props.attachment` is read, because it is
//! the one field this route needs to authorize - the same `may_link` check a
//! message's attachment already passes through, so pasting bytes onto a
//! canvas can grant no wider a reach than sending them ever could. Every
//! other field, and every field of every other kind, stays opaque the way the
//! read's degrade-to-`{}` already assumes; a schema per kind would make the
//! "kind-specific, opaque" column a lie. The residual is that an object whose
//! points (or, for an image, declared box) run past what it claims paints
//! outside it and vanishes when the box leaves the viewport - a rendering
//! artifact produced by somebody already authorized to draw, not a privilege
//! escape.
//!
//! One thing to know before slice three: a timed-out member cannot mint a
//! LiveKit token at all (`TIMEOUT_DENY` removes `CONNECT`), which is the only
//! reason ephemeral ink over the SFU data channel is not already a way around
//! this - `can_publish_data` is derived from `USE_CANVAS`, which the mask
//! spares.

use std::sync::Arc;

use axum::extract::{Path, State};
use serde::Deserialize;
use serde_json::Value;

use super::AppState;
use super::canvas::CanvasObjectDto;
use super::error::ApiError;
use super::extract::{AuthedLimited, CANVAS, Json};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{CanvasObjectId, ChannelId};
use crate::media;
use crate::permissions::Permissions;
use crate::store::PlaceError;

/// Largest serialized `props` one object may carry.
///
/// Sized against the broadcast ring rather than against any one drawing: an
/// event carries the whole row, `Event` is `Clone`, and the hub buffers 1024
/// of them, so this is what stops a canvas burst from costing more resident
/// memory than the whole process budget. A stroke is split by the client on
/// this byte budget, not on a point count.
pub(super) const MAX_PROPS_BYTES: usize = 4 * 1024;

/// The whole request body, which is `props` plus a small fixed envelope.
pub(super) const MAX_BODY_BYTES: usize = 8 * 1024;

/// Object kinds this server accepts.
///
/// An allowlist rather than the free text the store takes: `kind` decides how
/// every client renders a row, and an unknown one is a row nobody can draw and
/// nobody can remove. Per decision 0004 there is no `window` kind: a window is
/// a behaviour of an object, not an object. `note` and `shape` are the other
/// two tools decision 0004 names for the dock; neither needs a validation
/// exception the way `image` does, since neither carries a field this route
/// authorizes against - a note's text and a shape's own primitive both stay
/// inside the opaque `props` every other kind's fields already do.
const KINDS: [&str; 4] = ["stroke", "image", "note", "shape"];

/// The only kind-specific field this server reads out of an otherwise opaque
/// `props`: which attachment an `image` object names. A raw sha256, not a hex
/// string parsed lazily inside the store, so a malformed reference is a 400
/// naming the field rather than an internal error surfacing from a query.
fn image_attachment(props: &Value) -> Result<Vec<u8>, ApiError> {
    let raw = props
        .get("attachment")
        .and_then(Value::as_str)
        .ok_or(ApiError::BadRequest(
            "an image object needs props.attachment",
        ))?;
    media::from_hex(raw)
        .filter(|bytes| bytes.len() == 32)
        .ok_or(ApiError::BadRequest(
            "props.attachment is not a valid attachment id",
        ))
}

#[derive(Deserialize)]
pub(super) struct PlaceParams {
    /// Client-generated UUIDv7, and the idempotency key.
    id: String,
    kind: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    props: Value,
}

/// `POST /channels/{channel_id}/canvas/objects`.
///
/// Idempotent by `id`: a replay answers with the stored row, its original
/// `seq` intact, writes nothing, and - the part worth stating - publishes
/// nothing, so a retry after a lost response cannot fan a duplicate frame out
/// to every viewer.
pub(super) async fn place(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(params): Json<PlaceParams>,
) -> Result<(axum::http::StatusCode, Json<CanvasObjectDto>), ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let id = CanvasObjectId(parse_uuid(&params.id)?);

    // One per-channel evaluation, as the read does, so a missing channel and a forbidden one look alike.
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS)) {
        return Err(ApiError::Forbidden);
    }
    if state.store.timed_out_until(ctx.user_id).await?.is_some() {
        return Err(ApiError::Forbidden);
    }

    if !KINDS.contains(&params.kind.as_str()) {
        return Err(ApiError::BadRequest("unknown canvas object kind"));
    }
    if !params.props.is_object() {
        return Err(ApiError::BadRequest("canvas props must be an object"));
    }
    let props = serde_json::to_string(&params.props).map_err(|_| ApiError::Internal)?;
    if props.len() > MAX_PROPS_BYTES {
        return Err(ApiError::BadRequest("canvas props are too large"));
    }
    let attachment = if params.kind == "image" {
        Some(image_attachment(&params.props)?)
    } else {
        None
    };

    let placement = state
        .store
        .place_canvas_object(
            channel_id,
            ctx.user_id,
            id,
            crate::store::PlaceRequest {
                kind: &params.kind,
                bounds: (params.x, params.y, params.w, params.h),
                props: &props,
                attachment: attachment.as_deref(),
            },
        )
        .await;
    let placement = match placement {
        Ok(placement) => placement,
        Err(PlaceError::OutOfBounds) => {
            return Err(ApiError::BadRequest(
                "the object is outside the world or too large",
            ));
        }
        Err(PlaceError::ChannelFull) => return Err(ApiError::Conflict("this canvas is full")),
        Err(PlaceError::IdConflict) => {
            return Err(ApiError::Conflict("canvas object id already used"));
        }
        Err(PlaceError::Removed) => {
            return Err(ApiError::Conflict("that object was removed"));
        }
        Err(PlaceError::AttachmentNotFound) => {
            return Err(ApiError::BadRequest(
                "attachment not found; upload it first",
            ));
        }
        Err(PlaceError::NotAPicture) => {
            return Err(ApiError::BadRequest(
                "an image object must name a picture attachment",
            ));
        }
        Err(PlaceError::Internal(err)) => return Err(err.into()),
    };

    // No await between the commit and this call; see `ws::permission_cache`.
    if placement.fresh {
        state.hub.publish(Event::CanvasObjectPlaced {
            channel_id,
            object: Arc::new(placement.object.clone()),
        });
    }

    Ok((
        axum::http::StatusCode::CREATED,
        Json(CanvasObjectDto::from(placement.object)),
    ))
}

#[cfg(test)]
mod tests {
    use super::image_attachment;
    use serde_json::json;

    #[test]
    fn a_valid_attachment_id_parses_to_thirty_two_bytes() {
        let props = json!({ "attachment": "0".repeat(64) });
        let Ok(bytes) = image_attachment(&props) else {
            panic!("a well-formed 32-byte id parses");
        };
        assert_eq!(bytes.len(), 32);
    }

    /// The field must be present and a string: a missing key and a non-string
    /// value are both refused, so an image object can never be placed pointing
    /// at nothing.
    #[test]
    fn a_missing_or_non_string_attachment_is_refused() {
        assert!(image_attachment(&json!({})).is_err());
        assert!(image_attachment(&json!({ "attachment": 7 })).is_err());
    }

    #[test]
    fn a_malformed_or_wrong_length_attachment_is_refused() {
        assert!(image_attachment(&json!({ "attachment": "not hex" })).is_err());
        assert!(image_attachment(&json!({ "attachment": "abcd" })).is_err());
    }
}
