// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which canvases one connection has open, so a live cursor or preview is only
//! sent to a socket that can draw it.

use std::collections::HashSet;

use crate::hub::Event;
use crate::ids::{ChannelId, UserId};

/// More than a person has open at once; the rest of a report is ignored.
const MAX_WATCHED_CANVASES: usize = 8;

/// A connection's declared canvases. It starts undeclared and then delivers every
/// channel, so a client that predates `canvas.watch` keeps today's behaviour.
#[derive(Default)]
pub(super) struct CanvasWatch {
    declared: Option<HashSet<ChannelId>>,
}

impl CanvasWatch {
    /// Replaces the report; an empty list declares that no canvas is open.
    pub(super) fn declare(&mut self, channel_ids: &[String]) {
        self.declared = Some(
            channel_ids
                .iter()
                .take(MAX_WATCHED_CANVASES)
                .filter_map(|raw| uuid::Uuid::parse_str(raw).ok())
                .map(ChannelId)
                .collect(),
        );
    }

    /// Whether an ephemeral canvas frame is worth sending to this connection.
    /// Every other event passes: only the pointer-rate frames are filtered.
    pub(super) fn admits(&self, event: &Event, viewer: UserId) -> bool {
        let Some((channel_id, sender)) = ephemeral_canvas_origin(event) else {
            return true;
        };
        // Every client drops its own user's frames, and the sender already drew it.
        if sender == viewer {
            return false;
        }
        self.declared
            .as_ref()
            .is_none_or(|watched| watched.contains(&channel_id))
    }
}

fn ephemeral_canvas_origin(event: &Event) -> Option<(ChannelId, UserId)> {
    match event {
        Event::CanvasCursorMoved {
            channel_id,
            user_id,
            ..
        }
        | Event::CanvasStrokePreview {
            channel_id,
            user_id,
            ..
        }
        | Event::CanvasObjectPreview {
            channel_id,
            user_id,
            ..
        }
        | Event::CanvasMediaSlotPreview {
            channel_id,
            user_id,
            ..
        } => Some((*channel_id, *user_id)),
        _ => None,
    }
}
