// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas op stream's catch-up feed.
//!
//! A sibling of [`super`] rather than part of it, the way
//! [`super::canvas_write`] already is. Unlike the viewport read, this cursor
//! is stable and paging is correct: every op has its own seq value and there
//! are no ties, so a page boundary is never ambiguous the way a spatial
//! region's "ask for a smaller viewport" advice is.
//!
//! Every mutation writes exactly one op in the same transaction that
//! allocates its seq (see [`crate::store::canvas::canvas_ops`]), which is what makes
//! `after_seq` a real cursor: `seq == cursor + 1` is a legitimate gap
//! detector rather than a heuristic over a sparse space.

use axum::extract::{Path, State};
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AuthedLimited, CANVAS, Json, Query};
use super::super::messages::parse_uuid;
use super::CanvasObjectDto;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::store::{CanvasOpBody, CanvasOpEntry};

/// Default and maximum ops returned for one page of the feed.
///
/// Lower than the viewport read's own limit: a `place` op carries whole props
/// at up to `MAX_PROPS_BYTES`, so a row-count ceiling here bounds a page at an
/// order of magnitude under the viewport read's worst case, and
/// [`crate::store::CANVAS_OP_PAGE_BYTES`] is what actually stops a page of
/// large props from growing past that regardless of row count.
const DEFAULT_LIMIT: i64 = 100;
const MAX_LIMIT: i64 = 200;

#[derive(Deserialize)]
pub(in crate::http) struct ListOpsParams {
    after_seq: i64,
    limit: Option<i64>,
}

#[derive(Serialize)]
pub(in crate::http) struct CanvasOpsPageDto {
    ops: Vec<CanvasOpDto>,
    latest_seq: i64,
    has_more: bool,
    reset: bool,
}

#[derive(Serialize)]
struct CanvasOpDto {
    seq: i64,
    id: String,
    actor_id: Option<String>,
    created_at: i64,
    #[serde(flatten)]
    body: CanvasOpBodyDto,
}

#[derive(Serialize)]
/// The wire discriminant is the variant name itself, lowercased.
#[serde(tag = "kind", rename_all = "lowercase")]
enum CanvasOpBodyDto {
    /// Absent when the placed object has since been removed: a client should
    /// not paint an object the server no longer holds live.
    Place {
        #[serde(skip_serializing_if = "Option::is_none")]
        object: Option<CanvasObjectDto>,
    },
    Remove {
        object_ids: Vec<String>,
    },
    Clear {
        before_seq: i64,
    },
    /// A distinct kind so a client that predates scoped clears treats it as unknown and resyncs rather than clearing everything.
    #[serde(rename = "clear_scoped")]
    ClearScoped {
        before_seq: i64,
        kinds: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        author_id: Option<String>,
    },
    Restore {
        target_op: String,
        object_ids: Vec<String>,
    },
    Move {
        object_id: String,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
    Reorder {
        object_id: String,
        z_index: i64,
    },
    Edit {
        object_id: String,
        props: serde_json::Value,
    },
}

impl CanvasOpDto {
    /// Builds one op's wire form, disclosing the actor only where the live
    /// path already would.
    ///
    /// [`Event::CanvasObjectsRemoved`] omits the actor deliberately, "so a
    /// moderation act does not name its moderator to the whole channel", and
    /// this feed handed the same channel exactly what that withholds - and
    /// more reliably, since a live frame is ephemeral and this is a durable
    /// read anybody with `USE_CANVAS` can make at any time.
    ///
    /// A `place` keeps its actor, because it is not a moderation act and the
    /// same id is already public: `CanvasObject.author_id` is on the viewport
    /// read and documented in the schema, so withholding it here would hide
    /// nothing while making two reads of the same fact disagree.
    ///
    /// `moderates` is the caller's own `MANAGE_CANVAS`, so a moderator still
    /// sees the full trail. That is the point of keeping the ops table
    /// uncompacted: the record of who removed what has to survive somewhere,
    /// it just must not be readable by the whole channel.
    fn from_entry(entry: CanvasOpEntry, moderates: bool) -> Self {
        let is_moderation = !matches!(entry.body, CanvasOpBody::Place(_));
        let actor_id = if is_moderation && !moderates {
            None
        } else {
            entry.actor_id.map(|id| id.to_string())
        };
        let body = match entry.body {
            CanvasOpBody::Place(object) => CanvasOpBodyDto::Place {
                object: object.map(CanvasObjectDto::from),
            },
            CanvasOpBody::Remove(object_ids) => CanvasOpBodyDto::Remove {
                object_ids: ids(object_ids),
            },
            CanvasOpBody::Clear { before_seq, scope } if scope.is_unscoped() => {
                CanvasOpBodyDto::Clear { before_seq }
            }
            CanvasOpBody::Clear { before_seq, scope } => CanvasOpBodyDto::ClearScoped {
                before_seq,
                kinds: scope.kinds,
                author_id: scope.author_id.map(|id| id.to_string()),
            },
            CanvasOpBody::Restore {
                target_op,
                object_ids,
            } => CanvasOpBodyDto::Restore {
                target_op: target_op.to_string(),
                object_ids: ids(object_ids),
            },
            CanvasOpBody::Move {
                object_id,
                x,
                y,
                w,
                h,
            } => CanvasOpBodyDto::Move {
                object_id: object_id.to_string(),
                x,
                y,
                w,
                h,
            },
            CanvasOpBody::Reorder { object_id, z_index } => CanvasOpBodyDto::Reorder {
                object_id: object_id.to_string(),
                z_index,
            },
            CanvasOpBody::Edit { object_id, props } => CanvasOpBodyDto::Edit {
                object_id: object_id.to_string(),
                props: serde_json::from_str(&props).unwrap_or(serde_json::Value::Null),
            },
        };
        Self {
            seq: entry.seq,
            id: entry.id.to_string(),
            actor_id,
            created_at: entry.created_at,
            body,
        }
    }
}

fn ids<T: std::fmt::Display>(values: Vec<T>) -> Vec<String> {
    values.iter().map(T::to_string).collect()
}

/// `GET /channels/{channel_id}/canvas/ops`.
///
/// Gate is byte-identical to the viewport read: `VIEW_CHANNEL` and
/// `USE_CANVAS`, evaluated for this channel, no timeout check, since this is
/// a read.
pub(in crate::http) async fn list_ops(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path(channel_id): Path<String>,
    Query(params): Query<ListOpsParams>,
    State(state): State<AppState>,
) -> Result<Json<CanvasOpsPageDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS)) {
        return Err(ApiError::Forbidden);
    }
    if params.after_seq < 0 {
        return Err(ApiError::BadRequest("after_seq must not be negative"));
    }
    let limit = params.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let moderates = permissions.contains(Permissions::MANAGE_CANVAS);

    let page = state
        .store
        .list_canvas_ops(channel_id, params.after_seq, limit)
        .await?;
    Ok(Json(CanvasOpsPageDto {
        ops: page
            .ops
            .into_iter()
            .map(|op| CanvasOpDto::from_entry(op, moderates))
            .collect(),
        latest_seq: page.latest_seq,
        has_more: page.has_more,
        reset: page.reset,
    }))
}
