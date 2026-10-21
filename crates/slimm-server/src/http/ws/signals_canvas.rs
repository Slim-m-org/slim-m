// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ephemeral canvas signals relayed over the socket: cursor, previews and view.

use std::sync::Arc;

use super::canvas_gate::{Frame, may_relay, relay_grant};
use super::permission_cache::PermissionCache;
use crate::hub::{Event, Hub};
use crate::ids::{CanvasObjectId, ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::{Class, RateLimiter};
use crate::store::{MediaSlotKind, SessionContext, Store, WORLD_LIMIT, valid_bounds};

/// A `canvas.cursor` frame's position and whether it reports leaving.
pub(super) struct CursorAt {
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) left: bool,
}

/// Relays a pointer position on a channel's canvas, if the rate limiter,
/// bounds check and channel permissions all allow it. Silent on every
/// rejection, the same treatment [`handle_typing`] gives a refused refresh:
/// a dropped cursor frame is worth nothing, never an error frame or a closed
/// socket.
///
/// The permission bar matches the canvas HTTP routes exactly (view plus
/// `USE_CANVAS`), and there is deliberately no timeout check: a timeout
/// freezes the pen, not the mouse, the same reasoning `submit_op` already
/// gives for letting a timed-out member erase their own ink.
pub(super) async fn handle_canvas_cursor(
    store: &Store,
    hub: &Hub,
    limiter: &RateLimiter,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    channel_id: &str,
    CursorAt { x, y, left }: CursorAt,
) {
    let Ok(channel_id) = uuid::Uuid::parse_str(channel_id) else {
        return;
    };
    let channel_id = ChannelId(channel_id);

    if !x.is_finite() || !y.is_finite() || x.abs() > WORLD_LIMIT || y.abs() > WORLD_LIMIT {
        return;
    }

    if !limiter.check(Class::CanvasCursor, &format!("u:{}", ctx.user_id)) {
        return;
    }

    hub.presence().touch(ctx.user_id);

    if !may_relay(store, hub, ctx, cache, channel_id, Frame::Pointer).await {
        return;
    }

    hub.publish(Event::CanvasCursorMoved {
        channel_id,
        user_id: ctx.user_id,
        x,
        y,
        left,
    });
}

/// Bound on how many coordinate pairs one in-flight stroke preview frame may
/// carry. A well-behaved client never approaches this - it flushes on a
/// timer and caps what it buffers - so this only ever refuses a frame
/// nobody's own throttle produced, and it is checked before the frame costs
/// anything against the byte-rate budget.
const MAX_STROKE_PREVIEW_POINTS: usize = 24;

/// One `canvas.stroke_preview` frame's fields, bundled so
/// [`handle_canvas_stroke_preview`] stays under the project's parameter cap.
pub(super) struct StrokePreviewFrame {
    pub(super) channel_id: String,
    pub(super) object_id: String,
    pub(super) points: Vec<f64>,
    pub(super) ended: bool,
    pub(super) color: Option<String>,
    pub(super) width: Option<f64>,
}

/// Longest colour key a preview may carry.
const MAX_PREVIEW_COLOR_LEN: usize = 32;

/// Widest pen, in world units, a preview may claim.
const MAX_PREVIEW_WIDTH: f64 = 256.0;

/// A colour key made only of identifier characters, or none.
fn valid_preview_color(color: Option<String>) -> Option<String> {
    color.filter(|c| {
        !c.is_empty()
            && c.len() <= MAX_PREVIEW_COLOR_LEN
            && c.chars()
                .all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-')
    })
}

/// A finite, positive width within the pen range, or none.
fn valid_preview_width(width: Option<f64>) -> Option<f64> {
    width.filter(|w| w.is_finite() && *w > 0.0 && *w <= MAX_PREVIEW_WIDTH)
}

/// Relays an in-flight stroke preview on a channel's canvas, if the
/// byte-rate limiter, bounds check, permissions and timeout all allow it.
/// Silent on every rejection, the same treatment [`handle_canvas_cursor`]
/// gives a refused frame.
///
/// Two departures from [`handle_canvas_cursor`], both because this frame
/// carries drawing content and a cursor's bare position does not: the rate
/// limiter charges `frame_bytes` rather than one flat token (see
/// [`crate::ratelimit::Class::CanvasStrokePreview`]), and a timed-out member
/// is refused directly - the same check `http::canvas_write`'s own doc names
/// as the one thing standing between a timeout and a second write path that
/// forgot to apply it.
pub(super) async fn handle_canvas_stroke_preview(
    store: &Store,
    hub: &Hub,
    limiter: &RateLimiter,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    frame: StrokePreviewFrame,
    frame_bytes: usize,
) {
    let Ok(channel_id) = uuid::Uuid::parse_str(&frame.channel_id) else {
        return;
    };
    let channel_id = ChannelId(channel_id);
    let Ok(object_id) = uuid::Uuid::parse_str(&frame.object_id) else {
        return;
    };
    let object_id = CanvasObjectId(object_id);

    if !frame.points.len().is_multiple_of(2) || frame.points.len() / 2 > MAX_STROKE_PREVIEW_POINTS {
        return;
    }
    if frame
        .points
        .iter()
        .any(|v| !v.is_finite() || v.abs() > WORLD_LIMIT)
    {
        return;
    }

    let key = format!("u:{}", ctx.user_id);
    if !limiter.check_weighted(Class::CanvasStrokePreview, &key, frame_bytes as f64) {
        return;
    }

    hub.presence().touch(ctx.user_id);

    // Unlike a cursor, this frame carries ink; see this function's own doc.
    if !may_relay(store, hub, ctx, cache, channel_id, Frame::Ink).await {
        return;
    }

    hub.publish(Event::CanvasStrokePreview {
        channel_id,
        user_id: ctx.user_id,
        object_id,
        points: Arc::new(frame.points),
        ended: frame.ended,
        color: valid_preview_color(frame.color),
        width: valid_preview_width(frame.width),
    });
}

/// One `canvas.view` frame's fields.
pub(super) struct ViewFrame {
    pub(super) channel_id: String,
    /// `[x, y, w, h]` in world units.
    pub(super) rect: [f64; 4],
    pub(super) summon: bool,
}

/// Relays the world rectangle a member is looking at. Gated exactly like a
/// cursor (view plus `USE_CANVAS`, no timeout check) and silent on every
/// rejection.
pub(super) async fn handle_canvas_view(
    store: &Store,
    hub: &Hub,
    limiter: &RateLimiter,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    frame: ViewFrame,
) {
    let Ok(channel_id) = uuid::Uuid::parse_str(&frame.channel_id) else {
        return;
    };
    let channel_id = ChannelId(channel_id);
    let [x, y, w, h] = frame.rect;
    if frame
        .rect
        .iter()
        .any(|v| !v.is_finite() || v.abs() > WORLD_LIMIT)
        || w <= 0.0
        || h <= 0.0
    {
        return;
    }
    if !limiter.check(Class::CanvasView, &format!("u:{}", ctx.user_id)) {
        return;
    }
    hub.presence().touch(ctx.user_id);

    if !may_relay(store, hub, ctx, cache, channel_id, Frame::Pointer).await {
        return;
    }

    hub.publish(Event::CanvasView {
        channel_id,
        user_id: ctx.user_id,
        x,
        y,
        w,
        h,
        summon: frame.summon,
    });
}

/// One `canvas.media_slot_preview` frame's fields.
pub(super) struct MediaSlotPreviewFrame {
    pub(super) channel_id: String,
    pub(super) kind: String,
    pub(super) slot_user_id: String,
    /// `[x, y, w, h]` in world units.
    pub(super) rect: [f64; 4],
    pub(super) ended: bool,
}

/// Relays a tile-drag preview under the same gate as the committed slot write: canvas access, not timed out, and the tile not locked; silent on every rejection.
pub(super) async fn handle_canvas_media_slot_preview(
    store: &Store,
    hub: &Hub,
    limiter: &RateLimiter,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    frame: MediaSlotPreviewFrame,
) {
    let (Ok(channel_id), Ok(slot_user_id), Some(kind)) = (
        uuid::Uuid::parse_str(&frame.channel_id),
        uuid::Uuid::parse_str(&frame.slot_user_id),
        MediaSlotKind::parse(&frame.kind),
    ) else {
        return;
    };
    let channel_id = ChannelId(channel_id);
    let slot_user_id = UserId(slot_user_id);
    let [x, y, w, h] = frame.rect;
    if !valid_bounds(x, y, w, h) {
        return;
    }
    let key = format!("u:{}", ctx.user_id);
    if !limiter.check(Class::CanvasObjectPreview, &key) {
        return;
    }
    hub.presence().touch(ctx.user_id);

    if relay_grant(store, hub, ctx, cache, channel_id, Frame::Ink)
        .await
        .is_none()
    {
        return;
    }
    let locked = store
        .canvas_media_slot_locked(channel_id, slot_user_id, kind)
        .await;
    if locked.unwrap_or(true) {
        return;
    }

    hub.publish(Event::CanvasMediaSlotPreview {
        channel_id,
        user_id: ctx.user_id,
        kind,
        slot_user_id,
        x,
        y,
        w,
        h,
        ended: frame.ended,
    });
}

/// One `canvas.object_preview` frame's fields.
pub(super) struct ObjectPreviewFrame {
    pub(super) channel_id: String,
    pub(super) object_id: String,
    /// `[x, y, w, h]` in world units.
    pub(super) rect: [f64; 4],
    pub(super) ended: bool,
}

/// Relays a drag or resize preview if the limiter, bounds, permissions and
/// timeout allow it; silent on every rejection like its siblings.
pub(super) async fn handle_canvas_object_preview(
    store: &Store,
    hub: &Hub,
    limiter: &RateLimiter,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    frame: ObjectPreviewFrame,
) {
    let (Ok(channel_id), Ok(object_id)) = (
        uuid::Uuid::parse_str(&frame.channel_id),
        uuid::Uuid::parse_str(&frame.object_id),
    ) else {
        return;
    };
    let channel_id = ChannelId(channel_id);
    let [x, y, w, h] = frame.rect;
    if !valid_bounds(x, y, w, h) {
        return;
    }
    let key = format!("u:{}", ctx.user_id);
    if !limiter.check(Class::CanvasObjectPreview, &key) {
        return;
    }
    hub.presence().touch(ctx.user_id);

    let Some(granted) = relay_grant(store, hub, ctx, cache, channel_id, Frame::Ink).await else {
        return;
    };
    let object_id = CanvasObjectId(object_id);
    let may_moderate = granted.contains(Permissions::MANAGE_CANVAS);
    let now = std::time::Instant::now();
    if !cache.previewable(channel_id, object_id, now) {
        let movable = store
            .canvas_object_movable_by(channel_id, object_id, ctx.user_id, may_moderate)
            .await;
        if !movable.unwrap_or(false) {
            return;
        }
        cache.insert_previewable(channel_id, object_id, now);
    }

    hub.publish(Event::CanvasObjectPreview {
        channel_id,
        user_id: ctx.user_id,
        object_id,
        x,
        y,
        w,
        h,
        ended: frame.ended,
    });
}
