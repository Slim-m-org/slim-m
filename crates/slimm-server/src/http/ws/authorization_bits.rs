// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which permission bit each event needs beyond `VIEW_CHANNEL`, split from
//! `authorization.rs` for the line budget.

use crate::hub::{CanvasEvent, Event, MessageEvent};
use crate::permissions::Permissions;

/// The bit a frame needs beyond `VIEW_CHANNEL`, if any.
///
/// Exhaustive with no wildcard, so a new variant does not compile until
/// somebody classifies it - the same discipline `moves_permissions`
/// (`hub.rs`) already uses. Replaces a `matches!` naming one variant, which
/// would have shipped the next canvas event gated on `VIEW_CHANNEL` alone.
pub(super) fn extra_bit(event: &Event) -> Option<Permissions> {
    match event {
        Event::Canvas(CanvasEvent::ObjectPlaced { .. })
        | Event::Canvas(CanvasEvent::ObjectsRemoved { .. })
        | Event::Canvas(CanvasEvent::Cleared { .. })
        | Event::Canvas(CanvasEvent::ObjectsRestored { .. })
        | Event::Canvas(CanvasEvent::CursorMoved { .. })
        | Event::Canvas(CanvasEvent::StrokePreview { .. })
        | Event::Canvas(CanvasEvent::ObjectPreview { .. })
        | Event::Canvas(CanvasEvent::MediaSlotPreview { .. })
        | Event::Canvas(CanvasEvent::ScreenAnnotation(_))
        | Event::Canvas(CanvasEvent::View { .. })
        | Event::Canvas(CanvasEvent::ObjectMoved { .. })
        | Event::Canvas(CanvasEvent::ObjectReordered { .. })
        | Event::Canvas(CanvasEvent::ObjectEdited { .. })
        | Event::Canvas(CanvasEvent::MediaSlotChanged { .. })
        | Event::Canvas(CanvasEvent::ObjectLockChanged { .. }) => Some(Permissions::USE_CANVAS),
        Event::Message(MessageEvent::Created { .. })
        | Event::Message(MessageEvent::Edited { .. })
        | Event::Message(MessageEvent::Deleted { .. })
        | Event::Message(MessageEvent::ReactionsChanged { .. })
        | Event::Message(MessageEvent::CodeRunChanged { .. })
        | Event::Message(MessageEvent::CodeRunsCleared { .. })
        | Event::Message(MessageEvent::ThreadUpdated { .. })
        | Event::Message(MessageEvent::Pinned { .. })
        | Event::Message(MessageEvent::Unpinned { .. })
        | Event::Message(MessageEvent::PollVoted { .. })
        | Event::Message(MessageEvent::ComponentsChanged { .. })
        | Event::Message(MessageEvent::EmbedsChanged { .. })
        | Event::Message(MessageEvent::LinkPreviewsRemoved { .. })
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
        | Event::CallAudioChanged { .. }
        // Same again: a DM's own VIEW_CHANNEL already limits this to the pair.
        | Event::CallRinging { .. }
        | Event::CallRingEnded { .. }
        | Event::DmChanged { .. }
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
        | Event::SpaceSettingsChanged
        | Event::ReportsChanged
        | Event::ReadStateChanged { .. }
        | Event::NotificationOverrideChanged { .. }
        | Event::EphemeralMessage { .. }
        | Event::InteractionCreated { .. }
        | Event::InteractionAnswered { .. }
        | Event::InteractionForm { .. }
        | Event::NewDeviceSignIn { .. }
        | Event::VoiceMoved { .. }
        | Event::VoiceNotice { .. }
        | Event::VoiceSessionClosed { .. }
        | Event::Stamped { .. } => None,
    }
}
