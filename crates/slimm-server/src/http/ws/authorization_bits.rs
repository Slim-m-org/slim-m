// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which permission bit each event needs beyond `VIEW_CHANNEL`, split from
//! `authorization.rs` for the line budget.

use crate::hub::Event;
use crate::permissions::Permissions;

/// The bit a frame needs beyond `VIEW_CHANNEL`, if any.
///
/// Exhaustive with no wildcard, so a new variant does not compile until
/// somebody classifies it - the same discipline `moves_permissions`
/// (`hub.rs`) already uses. Replaces a `matches!` naming one variant, which
/// would have shipped the next canvas event gated on `VIEW_CHANNEL` alone.
pub(super) fn extra_bit(event: &Event) -> Option<Permissions> {
    match event {
        Event::CanvasObjectPlaced { .. }
        | Event::CanvasObjectsRemoved { .. }
        | Event::CanvasCleared { .. }
        | Event::CanvasObjectsRestored { .. }
        | Event::CanvasCursorMoved { .. }
        | Event::CanvasStrokePreview { .. }
        | Event::CanvasObjectMoved { .. }
        | Event::CanvasObjectReordered { .. }
        | Event::CanvasMediaSlotChanged { .. }
        | Event::CanvasObjectLockChanged { .. } => Some(Permissions::USE_CANVAS),
        Event::MessageCreated { .. }
        | Event::MessageEdited { .. }
        | Event::MessageDeleted { .. }
        | Event::ReactionsChanged { .. }
        | Event::CodeRunChanged { .. }
        | Event::CodeRunsCleared { .. }
        | Event::ThreadUpdated { .. }
        | Event::MessagePinned { .. }
        | Event::MessageUnpinned { .. }
        | Event::PollVoted { .. }
        | Event::MessageComponentsChanged { .. }
        | Event::MessageEmbedsChanged { .. }
        | Event::TypingStarted { .. }
        | Event::TypingStopped { .. }
        | Event::ChannelCreated(..)
        | Event::ChannelUpdated(..)
        | Event::OverwriteChanged { .. }
        // The same VIEW_CHANNEL gate the roster read route itself uses.
        | Event::VoiceActivityChanged { .. }
        | Event::VoiceParticipantJoined { .. }
        | Event::VoiceParticipantLeft { .. }
        | Event::VoiceScreenShareChanged { .. }
        | Event::WatchTick { .. }
        // Same again: a DM's own VIEW_CHANNEL already limits this to the pair.
        | Event::CallRinging { .. }
        | Event::CallRingEnded { .. }
        // Handled earlier in `authorize` and never reach this call.
        | Event::SessionRevoked(_)
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
        | Event::Stamped { .. } => None,
    }
}
