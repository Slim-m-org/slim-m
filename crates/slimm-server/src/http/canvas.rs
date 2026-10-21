// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Voice Canvas viewport read, backed by the R-Tree migration 0015 keeps
//! in sync.
//!
//! One route serves both the cold fetch and the pan. A client that is panning
//! sends the rectangle it is leaving alongside the one it is entering and gets
//! back only what it does not already hold; a client opening the canvas sends
//! the new rectangle alone. They are the same query with one extra predicate,
//! so they are one route rather than two that would drift apart.
//!
//! It is a pull, not a server-held subscription, and that is deliberate. The
//! client is the only party that knows when it panned, a pull keeps no
//! per-connection spatial state on the server to leak or to rebuild after a
//! reconnect, and a repeated pan is idempotent rather than a stream of
//! corrections. What it does not cover is objects removed while the caller was
//! looking at them: a soft delete does not advance the row's `seq`, so no
//! cursor over `canvas_objects` can observe one. That belongs to
//! [`self::canvas_ops`], the ordered feed over the op stream this route's
//! `latest_seq` is now a cursor into.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

use self::canvas_ops::list_ops;
use self::canvas_ops_write::submit_op;
use self::canvas_write::{MAX_BODY_BYTES, place};
use super::AppState;
use super::error::ApiError;
use super::extract::{AuthedLimited, CANVAS, Json, Query};
use super::messages::parse_uuid;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::store::{CanvasObject, Rect, ViewportQuery, WORLD_LIMIT};

pub(super) mod canvas_media_slots;
pub(super) mod canvas_object_locks;
pub(super) mod canvas_ops;
pub(super) mod canvas_ops_write;
pub(super) mod canvas_purge;
pub(super) mod canvas_write;

/// Default and maximum objects returned for one viewport read. The ceiling is
/// well above a screenful at any sane zoom, and is here so a client asking for
/// the whole world gets a bounded answer instead of the canvas.
const DEFAULT_LIMIT: i64 = 500;
const MAX_LIMIT: i64 = 2000;

/// The canvas routes, mounted by [`super::router`].
///
/// The body limit is on the router rather than either route, so a `remove`
/// or `clear` body is refused at the byte level the same way an over-large
/// `place` already is, before serde ever builds a `Value` several times its
/// wire size.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/canvas/objects",
            get(viewport).post(place),
        )
        .route(
            "/channels/{channel_id}/canvas/ops",
            get(list_ops).post(submit_op),
        )
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
}

// --- Wire types ---

#[derive(Deserialize)]
struct ViewportParams {
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
    prev_min_x: Option<f64>,
    prev_min_y: Option<f64>,
    prev_max_x: Option<f64>,
    prev_max_y: Option<f64>,
    after_seq: Option<i64>,
    limit: Option<i64>,
    /// Pages the region in `seq` order: objects after this seq, oldest first.
    cursor_seq: Option<i64>,
}

#[derive(Serialize)]
pub(crate) struct CanvasObjectDto {
    id: String,
    kind: String,
    z_index: i64,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    props: Box<RawValue>,
    author_id: Option<String>,
    seq: i64,
    created_at: i64,
}

impl From<CanvasObject> for CanvasObjectDto {
    fn from(object: CanvasObject) -> Self {
        Self {
            id: object.id.to_string(),
            kind: object.kind,
            z_index: object.z_index,
            x: object.x,
            y: object.y,
            w: object.w,
            h: object.h,
            // `props` is opaque to the server, so an unparseable one degrades
            // to an empty object rather than failing the whole viewport.
            props: RawValue::from_string(object.props)
                .unwrap_or_else(|_| RawValue::from_string("{}".to_owned()).expect("empty object")),
            author_id: object.author_id.map(|id| id.to_string()),
            seq: object.seq.0,
            created_at: object.created_at,
        }
    }
}

#[derive(Serialize)]
struct ViewportDto {
    objects: Vec<CanvasObjectDto>,
    /// More objects intersect this viewport than the limit allowed. A client
    /// seeing this should zoom in or raise its limit, not paginate: there is
    /// no stable cursor across a region query.
    has_more: bool,
    /// The channel's canvas high-water mark, to send back as `after_seq`.
    latest_seq: i64,
    /// A `cursor_seq` page only: send this back as `cursor_seq` for the next page, absent on the last.
    #[serde(skip_serializing_if = "Option::is_none")]
    next_cursor: Option<i64>,
    /// A `cursor_seq` page only: how many live objects the whole channel holds.
    #[serde(skip_serializing_if = "Option::is_none")]
    total_objects: Option<i64>,
}

// --- Handler ---

async fn viewport(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path(channel_id): Path<String>,
    Query(params): Query<ViewportParams>,
    State(state): State<AppState>,
) -> Result<Json<ViewportDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    // Both bits from one per-channel evaluation, in which a nonexistent
    // channel grants nothing, so a missing canvas is not distinguishable.
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS)) {
        return Err(ApiError::Forbidden);
    }

    let view = rect(params.min_x, params.min_y, params.max_x, params.max_y)?;
    let previous = match (
        params.prev_min_x,
        params.prev_min_y,
        params.prev_max_x,
        params.prev_max_y,
    ) {
        (Some(min_x), Some(min_y), Some(max_x), Some(max_y)) => {
            Some(rect(min_x, min_y, max_x, max_y)?)
        }
        (None, None, None, None) => None,
        _ => {
            return Err(ApiError::BadRequest(
                "the previous viewport needs all four bounds or none",
            ));
        }
    };

    let limit = params.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    if let Some(cursor_seq) = params.cursor_seq {
        if previous.is_some() || params.after_seq.is_some() || cursor_seq < 0 {
            return Err(ApiError::BadRequest(
                "cursor_seq cannot be combined with the previous viewport or after_seq",
            ));
        }
        return page_by_seq(&state, channel_id, view, cursor_seq, limit).await;
    }
    let query = ViewportQuery {
        view,
        previous,
        after_seq: params.after_seq.unwrap_or(0),
        // One over the limit, so "there are more" is answered by the same read
        // rather than a second counting query over the same region.
        limit: limit + 1,
    };

    // Both read from one deferred transaction (`Store::viewport_snapshot`), so
    // WAL gives them one snapshot: `latest_seq` means exactly "every op at or
    // below this is reflected in the objects just read". A write landing
    // between two separate reads could produce a cursor the page does not
    // cover; over-reporting instead self-heals on the next read.
    let (latest_seq, mut objects) = state.store.viewport_snapshot(channel_id, &query).await?;
    let mut has_more = objects.len() as i64 > limit;
    // From the front: the store reads newest-first and reverses, so the extra row is the oldest.
    if has_more {
        objects.drain(0..(objects.len() - limit as usize));
    }
    has_more |= trim_to_byte_budget(&mut objects, true);

    Ok(Json(ViewportDto {
        objects: objects.into_iter().map(CanvasObjectDto::from).collect(),
        has_more,
        latest_seq,
        next_cursor: None,
        total_objects: None,
    }))
}

/// Largest response body one read aims for, counting `OBJECT_ENVELOPE_BYTES` around each props; past it the read says `has_more`.
const MAX_RESPONSE_BYTES: usize = 900 * 1024;
/// What an object's fields other than `props` cost on the wire, rounded up.
const OBJECT_ENVELOPE_BYTES: usize = 300;

/// Drops objects past the byte budget, keeping at least one, from the oldest end when `drop_front`.
fn trim_to_byte_budget(objects: &mut Vec<CanvasObject>, drop_front: bool) -> bool {
    let mut spent = 0usize;
    let mut kept = 0usize;
    let ordered: Box<dyn Iterator<Item = &CanvasObject>> = if drop_front {
        Box::new(objects.iter().rev())
    } else {
        Box::new(objects.iter())
    };
    for object in ordered {
        spent += object.props.len() + OBJECT_ENVELOPE_BYTES;
        if kept > 0 && spent > MAX_RESPONSE_BYTES {
            break;
        }
        kept += 1;
    }
    if kept == objects.len() {
        return false;
    }
    if drop_front {
        objects.drain(0..(objects.len() - kept));
    } else {
        objects.truncate(kept);
    }
    true
}

/// A page of the region in `seq` order, so a client can load the rest of a big board in the background.
async fn page_by_seq(
    state: &AppState,
    channel_id: ChannelId,
    view: Rect,
    cursor_seq: i64,
    limit: i64,
) -> Result<Json<ViewportDto>, ApiError> {
    let (latest_seq, total, mut objects) = state
        .store
        .viewport_page(channel_id, view, cursor_seq, limit + 1)
        .await?;
    let mut has_more = objects.len() as i64 > limit;
    objects.truncate(limit as usize);
    has_more |= trim_to_byte_budget(&mut objects, false);
    let next_cursor = if has_more {
        objects.last().map(|object| object.seq.0)
    } else {
        None
    };
    Ok(Json(ViewportDto {
        objects: objects.into_iter().map(CanvasObjectDto::from).collect(),
        has_more,
        latest_seq,
        next_cursor,
        total_objects: Some(total),
    }))
}

/// Validates one rectangle. Clamping silently instead would answer a query the
/// caller did not ask, which on a canvas means quietly showing the wrong part
/// of the world.
fn rect(min_x: f64, min_y: f64, max_x: f64, max_y: f64) -> Result<Rect, ApiError> {
    let bounds = [min_x, min_y, max_x, max_y];
    if !bounds.iter().all(|v| v.is_finite()) {
        return Err(ApiError::BadRequest("viewport bounds must be finite"));
    }
    if min_x > max_x || min_y > max_y {
        return Err(ApiError::BadRequest("viewport bounds are inverted"));
    }
    if bounds.iter().any(|v| v.abs() > WORLD_LIMIT) {
        return Err(ApiError::BadRequest("viewport is outside the world"));
    }
    Ok(Rect {
        min_x,
        min_y,
        max_x,
        max_y,
    })
}
