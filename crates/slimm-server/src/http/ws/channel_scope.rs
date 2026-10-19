// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which channel's permissions decide whether a channel-scoped [`Event`]
//! reaches a connection.

use crate::hub::Event;
use crate::ids::ChannelId;

/// `None` for an event with no channel to check, which is never delivered past this point.
pub(super) fn channel_of(event: &Event) -> Option<ChannelId> {
    if let Some(channel_id) = super::canvas_frames::channel_id(event) {
        return Some(channel_id);
    }
    Some(match event {
        Event::MessageCreated { message, .. } => message.channel_id,
        Event::MessageEdited { message, .. } => message.channel_id,
        Event::MessageDeleted { channel_id, .. } => *channel_id,
        Event::ReactionsChanged { channel_id, .. } => *channel_id,
        Event::CodeRunChanged { channel_id, .. } => *channel_id,
        Event::CodeRunsCleared { channel_id, .. } => *channel_id,
        Event::ThreadUpdated { channel_id, .. } => *channel_id,
        Event::MessagePinned { channel_id, .. } => *channel_id,
        Event::MessageUnpinned { channel_id, .. } => *channel_id,
        Event::PollVoted { channel_id, .. } => *channel_id,
        Event::MessageComponentsChanged { channel_id, .. } => *channel_id,
        Event::MessageEmbedsChanged { channel_id, .. } => *channel_id,
        Event::TypingStarted { channel_id, .. } | Event::TypingStopped { channel_id, .. } => {
            *channel_id
        }
        Event::ChannelCreated(channel, _) | Event::ChannelUpdated(channel, _) => channel.id,
        Event::OverwriteChanged { channel_id, .. } => *channel_id,
        Event::VoiceActivityChanged { channel_id } => *channel_id,
        Event::VoiceParticipantJoined { channel_id, .. } => *channel_id,
        Event::VoiceParticipantLeft { channel_id, .. } => *channel_id,
        Event::VoiceScreenShareChanged { channel_id, .. } => *channel_id,
        Event::WatchTick { channel_id, .. } => *channel_id,
        Event::CallRinging { channel_id, .. } => *channel_id,
        Event::CallRingEnded { channel_id, .. } => *channel_id,
        // canvas_frames::channel_id already answered Some for any of these.
        Event::CanvasObjectPlaced { .. }
        | Event::CanvasObjectsRemoved { .. }
        | Event::CanvasCleared { .. }
        | Event::CanvasObjectsRestored { .. }
        | Event::CanvasCursorMoved { .. }
        | Event::CanvasStrokePreview { .. }
        | Event::CanvasObjectPreview { .. }
        | Event::CanvasView { .. }
        | Event::CanvasObjectMoved { .. }
        | Event::CanvasObjectReordered { .. }
        | Event::CanvasMediaSlotChanged { .. }
        | Event::CanvasObjectLockChanged { .. } => unreachable!("canvas_frames::channel_id"),
        // Control events are handled in the loop; the rest already returned above.
        Event::SessionRevoked(_)
        | Event::PresenceChanged(_)
        | Event::MemberTimeoutChanged { .. }
        | Event::JoinGateChanged { .. }
        | Event::MemberRemoved(_)
        | Event::MemberRestored(_)
        | Event::MemberJoined(_)
        | Event::ProfileChanged(_)
        | Event::BotUiChanged(_)
        | Event::RoleChanged { .. }
        | Event::MemberRoleChanged { .. }
        | Event::ChannelDeleted { .. }
        | Event::CategoryChanged
        | Event::ReportsChanged
        | Event::ReadStateChanged { .. }
        | Event::NotificationOverrideChanged { .. }
        | Event::EphemeralMessage { .. }
        | Event::InteractionCreated { .. }
        | Event::InteractionAnswered { .. }
        | Event::NewDeviceSignIn { .. }
        | Event::Stamped { .. } => return None,
    })
}
