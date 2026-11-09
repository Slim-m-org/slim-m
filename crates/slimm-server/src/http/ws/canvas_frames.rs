// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas [`Event`] variants: which channel one concerns, and its wire
//! frame. Split out of `authorization.rs` once adding
//! `canvas.media_slot.changed` there would have crossed the 500-line hard
//! ceiling.
//!
//! Each function lists every canvas variant exactly once in its own match,
//! rather than `authorization.rs` keeping a second, hand-kept list of
//! "which events are canvas events" to dispatch on: [`to_frame`] hands a
//! non-canvas event straight back unconsumed, so `authorize`'s own general
//! match is what falls through to for anything this file does not know.

use std::sync::Arc;

use super::CanvasObjectDto;
use super::frames::ServerFrame;
use crate::hub::{CanvasEvent, Event, ScreenAnnotationEvent};
use crate::ids::ChannelId;

/// The channel a canvas event concerns, or `None` for anything else.
pub(super) fn channel_id(event: &Event) -> Option<ChannelId> {
    Some(match event {
        Event::Canvas(CanvasEvent::ObjectPlaced { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::ObjectsRemoved { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::Cleared { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::ObjectsRestored { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::CursorMoved { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::StrokePreview { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::ObjectPreview { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::MediaSlotPreview { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::ScreenAnnotation(a)) => a.channel_id,
        Event::Canvas(CanvasEvent::View { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::ObjectMoved { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::ObjectReordered { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::ObjectEdited { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::MediaSlotChanged { channel_id, .. }) => *channel_id,
        Event::Canvas(CanvasEvent::ObjectLockChanged { channel_id, .. }) => *channel_id,
        _ => return None,
    })
}

/// A canvas event's wire frame, or the event handed back unconsumed for
/// anything else. The error side is boxed for the same reason
/// `Authorization::Deliver` already boxes its own `ServerFrame`: `Event`'s
/// largest variant carries a whole `Message`, and a non-canvas event (the
/// common case) would otherwise pay for that on every call.
pub(super) fn to_frame(event: Event) -> Result<ServerFrame, Box<Event>> {
    Ok(match event {
        // Cloned only here, past every filter in `authorize`; see `MessageEvent::Created`'s own note.
        Event::Canvas(CanvasEvent::ObjectPlaced { channel_id, object }) => {
            ServerFrame::CanvasObjectPlaced {
                channel_id: channel_id.to_string(),
                seq: object.seq.0,
                object: CanvasObjectDto::from((*object).clone()),
            }
        }
        Event::Canvas(CanvasEvent::ObjectsRemoved {
            channel_id,
            seq,
            op_id,
            object_ids,
        }) => ServerFrame::CanvasObjectsRemoved {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_ids: object_ids.iter().map(ToString::to_string).collect(),
        },
        Event::Canvas(CanvasEvent::Cleared {
            channel_id,
            seq,
            op_id,
            before_seq,
            scope,
            spared_count,
            ..
        }) if scope.is_unscoped() && spared_count == 0 => ServerFrame::CanvasCleared {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            before_seq: before_seq.0,
        },
        Event::Canvas(CanvasEvent::Cleared {
            channel_id,
            seq,
            op_id,
            before_seq,
            scope,
            spared_ids,
            spared_count,
        }) => ServerFrame::CanvasClearedScoped {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            before_seq: before_seq.0,
            kinds: scope.kinds.clone(),
            author_id: scope.author_id.map(|id| id.to_string()),
            spared_ids: spared_ids.iter().map(ToString::to_string).collect(),
            spared_count,
        },
        Event::Canvas(CanvasEvent::ObjectsRestored {
            channel_id,
            seq,
            op_id,
            object_ids,
        }) => ServerFrame::CanvasObjectsRestored {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_ids: object_ids.iter().map(ToString::to_string).collect(),
        },
        Event::Canvas(CanvasEvent::CursorMoved {
            channel_id,
            user_id,
            x,
            y,
            left,
        }) => ServerFrame::CanvasCursorMoved {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
            x,
            y,
            left,
        },
        Event::Canvas(CanvasEvent::StrokePreview {
            channel_id,
            user_id,
            object_id,
            points,
            ended,
            cancelled,
            color,
            width,
        }) => ServerFrame::CanvasStrokePreview {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
            object_id: object_id.to_string(),
            points: points.to_vec(),
            ended,
            cancelled,
            color,
            width,
        },
        Event::Canvas(CanvasEvent::ObjectPreview {
            channel_id,
            user_id,
            object_id,
            x,
            y,
            w,
            h,
            ended,
        }) => ServerFrame::CanvasObjectPreview {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
            object_id: object_id.to_string(),
            x,
            y,
            w,
            h,
            ended,
        },
        Event::Canvas(CanvasEvent::MediaSlotPreview {
            channel_id,
            user_id,
            kind,
            slot_user_id,
            x,
            y,
            w,
            h,
            ended,
        }) => ServerFrame::CanvasMediaSlotPreview {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
            kind: kind.as_str().to_owned(),
            slot_user_id: slot_user_id.to_string(),
            x,
            y,
            w,
            h,
            ended,
        },
        Event::Canvas(CanvasEvent::ScreenAnnotation(a)) => {
            annotation_frame(Arc::unwrap_or_clone(a))
        }
        Event::Canvas(CanvasEvent::View {
            channel_id,
            user_id,
            x,
            y,
            w,
            h,
            summon,
            tile,
        }) => ServerFrame::CanvasView {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
            x,
            y,
            w,
            h,
            summon,
            tile,
        },
        Event::Canvas(CanvasEvent::ObjectMoved {
            channel_id,
            seq,
            op_id,
            object_id,
            x,
            y,
            w,
            h,
        }) => ServerFrame::CanvasObjectMoved {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_id: object_id.to_string(),
            x,
            y,
            w,
            h,
        },
        Event::Canvas(CanvasEvent::ObjectReordered {
            channel_id,
            seq,
            op_id,
            object_id,
            z_index,
        }) => ServerFrame::CanvasObjectReordered {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_id: object_id.to_string(),
            z_index,
        },
        Event::Canvas(CanvasEvent::ObjectEdited {
            channel_id,
            seq,
            op_id,
            object_id,
            props,
        }) => ServerFrame::CanvasObjectEdited {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_id: object_id.to_string(),
            props: serde_json::from_str(&props).unwrap_or(serde_json::Value::Null),
        },
        Event::Canvas(CanvasEvent::MediaSlotChanged {
            channel_id,
            kind,
            user_id,
            x,
            y,
            w,
            h,
            locked,
            sent_to_back,
            version,
        }) => ServerFrame::CanvasMediaSlotChanged {
            channel_id: channel_id.to_string(),
            kind: kind.as_str().to_owned(),
            user_id: user_id.to_string(),
            x,
            y,
            w,
            h,
            locked,
            sent_to_back,
            version,
        },
        Event::Canvas(CanvasEvent::ObjectLockChanged {
            channel_id,
            object_id,
            locked,
            version,
        }) => ServerFrame::CanvasObjectLockChanged {
            channel_id: channel_id.to_string(),
            object_id: object_id.to_string(),
            locked,
            version,
        },
        other => return Err(Box::new(other)),
    })
}

fn annotation_frame(a: ScreenAnnotationEvent) -> ServerFrame {
    ServerFrame::CanvasScreenAnnotation {
        channel_id: a.channel_id.to_string(),
        user_id: a.user_id.to_string(),
        target_user_id: a.target_user_id.to_string(),
        kind: a.kind.as_str().to_owned(),
        annotation_id: a.annotation_id.map(|id| id.to_string()),
        points: a.points,
        color: a.color,
        text: a.text,
        ended: a.ended,
        allowed: a.allowed,
        aspect: a.aspect,
    }
}
