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

use super::CanvasObjectDto;
use super::frames::ServerFrame;
use crate::hub::Event;
use crate::ids::ChannelId;

/// The channel a canvas event concerns, or `None` for anything else.
pub(super) fn channel_id(event: &Event) -> Option<ChannelId> {
    Some(match event {
        Event::CanvasObjectPlaced { channel_id, .. } => *channel_id,
        Event::CanvasObjectsRemoved { channel_id, .. } => *channel_id,
        Event::CanvasCleared { channel_id, .. } => *channel_id,
        Event::CanvasObjectsRestored { channel_id, .. } => *channel_id,
        Event::CanvasCursorMoved { channel_id, .. } => *channel_id,
        Event::CanvasStrokePreview { channel_id, .. } => *channel_id,
        Event::CanvasObjectMoved { channel_id, .. } => *channel_id,
        Event::CanvasObjectReordered { channel_id, .. } => *channel_id,
        Event::CanvasMediaSlotChanged { channel_id, .. } => *channel_id,
        Event::CanvasObjectLockChanged { channel_id, .. } => *channel_id,
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
        // Cloned only here, past every filter in `authorize`; see `Event::MessageCreated`'s own note.
        Event::CanvasObjectPlaced { channel_id, object } => ServerFrame::CanvasObjectPlaced {
            channel_id: channel_id.to_string(),
            seq: object.seq.0,
            object: CanvasObjectDto::from((*object).clone()),
        },
        Event::CanvasObjectsRemoved {
            channel_id,
            seq,
            op_id,
            object_ids,
        } => ServerFrame::CanvasObjectsRemoved {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_ids: object_ids.iter().map(ToString::to_string).collect(),
        },
        Event::CanvasCleared {
            channel_id,
            seq,
            op_id,
            before_seq,
        } => ServerFrame::CanvasCleared {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            before_seq: before_seq.0,
        },
        Event::CanvasObjectsRestored {
            channel_id,
            seq,
            op_id,
            object_ids,
        } => ServerFrame::CanvasObjectsRestored {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_ids: object_ids.iter().map(ToString::to_string).collect(),
        },
        Event::CanvasCursorMoved {
            channel_id,
            user_id,
            x,
            y,
        } => ServerFrame::CanvasCursorMoved {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
            x,
            y,
        },
        Event::CanvasStrokePreview {
            channel_id,
            user_id,
            object_id,
            points,
            ended,
        } => ServerFrame::CanvasStrokePreview {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
            object_id: object_id.to_string(),
            points,
            ended,
        },
        Event::CanvasObjectMoved {
            channel_id,
            seq,
            op_id,
            object_id,
            x,
            y,
            w,
            h,
        } => ServerFrame::CanvasObjectMoved {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_id: object_id.to_string(),
            x,
            y,
            w,
            h,
        },
        Event::CanvasObjectReordered {
            channel_id,
            seq,
            op_id,
            object_id,
            z_index,
        } => ServerFrame::CanvasObjectReordered {
            channel_id: channel_id.to_string(),
            seq: seq.0,
            op_id: op_id.to_string(),
            object_id: object_id.to_string(),
            z_index,
        },
        Event::CanvasMediaSlotChanged {
            channel_id,
            kind,
            user_id,
            x,
            y,
            w,
            h,
            locked,
            sent_to_back,
        } => ServerFrame::CanvasMediaSlotChanged {
            channel_id: channel_id.to_string(),
            kind: kind.as_str().to_owned(),
            user_id: user_id.to_string(),
            x,
            y,
            w,
            h,
            locked,
            sent_to_back,
        },
        Event::CanvasObjectLockChanged {
            channel_id,
            object_id,
            locked,
        } => ServerFrame::CanvasObjectLockChanged {
            channel_id: channel_id.to_string(),
            object_id: object_id.to_string(),
            locked,
        },
        other => return Err(Box::new(other)),
    })
}
