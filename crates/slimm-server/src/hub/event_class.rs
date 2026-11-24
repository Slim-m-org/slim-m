// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How [`super::Hub::publish`] classifies an event: whether it moves somebody's
//! permissions, and which of the two channels it fans out on.

use super::{CanvasEvent, Event, MessageEvent};

/// Whether this event means somebody's permissions may have moved.
///
/// Exhaustive on purpose: a new variant does not compile until somebody
/// decides, and the safe answer for anything permission-shaped is `true`.
/// Over-reporting only costs a re-derivation; under-reporting is a stale
/// answer served to a caller who should no longer have it.
pub(crate) fn moves_permissions(event: &Event) -> bool {
    match event {
        Event::RoleChanged { .. }
        | Event::MemberRoleChanged { .. }
        | Event::MemberTimeoutChanged { .. }
        | Event::JoinGateChanged { .. }
        | Event::MemberRemoved(_)
        | Event::MemberRestored(_)
        | Event::OwnerChanged(_)
        | Event::OverwriteChanged { .. }
        | Event::ChannelCreated(..)
        | Event::ChannelUpdated(..)
        | Event::ChannelDeleted { .. }
        // A roster change is a permission change for the person added or removed.
        | Event::DmChanged { .. } => true,
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
        | Event::Message(MessageEvent::VoiceTranscript { .. })
        | Event::Message(MessageEvent::LinkPreviewsRemoved { .. })
        | Event::TypingStarted { .. }
        | Event::TypingStopped { .. }
        | Event::PresenceChanged(_)
        | Event::ProfileChanged(_)
        | Event::BotUiChanged(_)
        | Event::Canvas(CanvasEvent::ObjectPlaced { .. })
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
        | Event::Canvas(CanvasEvent::ObjectLockChanged { .. })
        | Event::Canvas(CanvasEvent::TileSceneChanged { .. })
        | Event::SessionRevoked(_)
        | Event::AccountSessionsRevoked { .. }
        // A join changes nobody's existing cached answer; see the variant's own doc.
        | Event::MemberJoined(_)
        // Who is on a call changes no permission's answer.
        | Event::VoiceActivityChanged { .. }
        | Event::VoiceParticipantJoined { .. }
        | Event::VoiceParticipantLeft { .. }
        | Event::VoiceScreenShareChanged { .. }
        | Event::WatchTick { .. }
        | Event::CallAudioChanged { .. }
        | Event::CallTranscriptChanged { .. }
        | Event::ModuleRoomChanged(_)
        | Event::ConnectorRun(_)
        | Event::CallTranscriptLine { .. }
        | Event::CallTranscriptMarkChanged { .. }
        // Ringing, and how a ring ended, changes no permission's answer either.
        | Event::CallRinging { .. }
        | Event::CallRingEnded { .. }
        // A category grants and denies nothing (docs/decisions/0006).
        | Event::CategoryChanged
        | Event::SpaceSettingsChanged
        | Event::SpaceThemesChanged
        // A report being filed or resolved changes no permission's answer either.
        | Event::ReportsChanged
        | Event::AdminAlertsChanged
        // Private notices and read markers move no permission and need no fan-out ordering.
        | Event::ReadStateChanged { .. }
        | Event::NotificationOverrideChanged { .. }
        | Event::CategoryMuteChanged { .. }
        | Event::EphemeralMessage { .. }
        | Event::InteractionCreated { .. }
        | Event::InteractionAnswered { .. }
        | Event::InteractionForm { .. }
        | Event::NewDeviceSignIn { .. }
        | Event::VoiceMoved { .. }
        | Event::VoiceRemoved { .. }
        | Event::VoiceNotice { .. }
        | Event::SoundboardPlayed { .. }
        // Internal to the module event consumer; it moves no permission.
        | Event::VoiceSessionClosed { .. } => false,
        Event::Stamped { event, .. } => moves_permissions(event),
    }
}

/// Whether this event belongs on the ephemeral channel rather than the
/// durable one - see [`crate::hub`]'s own doc comment for what that split means.
///
/// Exhaustive on purpose, the same discipline [`moves_permissions`] already
/// uses: a new variant does not compile until somebody decides which channel
/// it fans out on, and the safe default is durable, not ephemeral, since a
/// dropped durable event is a much larger surprise than a slightly stale
/// cursor.
///
/// [`Event::EphemeralMessage`] rides here too, being unnumbered and never
/// stored, at a rate a bot's write limit keeps far below the cursors'.
/// Otherwise only the live canvas frames qualify - [`CanvasEvent::CursorMoved`],
/// [`CanvasEvent::StrokePreview`], [`CanvasEvent::ObjectPreview`] and
/// [`CanvasEvent::View`] - plus [`Event::WatchTick`]: each is rate-limited well above what a human notices, carry no
/// `seq`, are never persisted, and have no catch-up path a reconnect could use
/// anyway (see their own doc comments in `hub/event/`). `TypingStarted`/
/// `TypingStopped` are ephemeral in the same sense but stay durable here: they
/// are rate-limited far lower (`Class::Typing`: 2/sec sustained against
/// `CanvasCursor`'s 15/sec), they come in explicit start/stop pairs rather
/// than a stream a receiver ages out on its own, and a dropped `Stopped` on a
/// lossy channel would leave a "someone is typing" indicator stuck until the
/// next unrelated typing refresh from that user - worse than the bounded
/// staleness a lost cursor produces. Moving them costs a decision with a real
/// downside for a rate that page rarely approaches the durable channel's own
/// capacity in the first place.
pub(super) fn is_ephemeral(event: &Event) -> bool {
    match event {
        Event::Canvas(CanvasEvent::CursorMoved { .. })
        | Event::Canvas(CanvasEvent::StrokePreview { .. })
        | Event::Canvas(CanvasEvent::ObjectPreview { .. })
        | Event::Canvas(CanvasEvent::MediaSlotPreview { .. })
        | Event::Canvas(CanvasEvent::ScreenAnnotation(_))
        | Event::Canvas(CanvasEvent::View { .. })
        | Event::WatchTick { .. }
        | Event::EphemeralMessage { .. }
        | Event::SoundboardPlayed { .. }
        | Event::InteractionCreated { .. }
        | Event::InteractionAnswered { .. }
        | Event::ConnectorRun(_)
        // Lossy on purpose: reading the message is the catch-up.
        | Event::Message(MessageEvent::VoiceTranscript { .. })
        | Event::InteractionForm { .. } => true,
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
        | Event::PresenceChanged(_)
        | Event::ProfileChanged(_)
        | Event::BotUiChanged(_)
        | Event::RoleChanged { .. }
        | Event::MemberRoleChanged { .. }
        | Event::MemberTimeoutChanged { .. }
        | Event::JoinGateChanged { .. }
        | Event::MemberRemoved(_)
        | Event::MemberRestored(_)
        | Event::MemberJoined(_)
        | Event::OwnerChanged(_)
        | Event::OverwriteChanged { .. }
        | Event::ChannelCreated(..)
        | Event::ChannelUpdated(..)
        | Event::ChannelDeleted { .. }
        | Event::CategoryChanged
        | Event::SpaceSettingsChanged
        | Event::SpaceThemesChanged
        | Event::Canvas(CanvasEvent::ObjectPlaced { .. })
        | Event::Canvas(CanvasEvent::ObjectsRemoved { .. })
        | Event::Canvas(CanvasEvent::Cleared { .. })
        | Event::Canvas(CanvasEvent::ObjectsRestored { .. })
        | Event::Canvas(CanvasEvent::ObjectMoved { .. })
        | Event::Canvas(CanvasEvent::ObjectReordered { .. })
        | Event::Canvas(CanvasEvent::ObjectEdited { .. })
        | Event::Canvas(CanvasEvent::MediaSlotChanged { .. })
        | Event::Canvas(CanvasEvent::ObjectLockChanged { .. })
        | Event::Canvas(CanvasEvent::TileSceneChanged { .. })
        | Event::SessionRevoked(_)
        | Event::AccountSessionsRevoked { .. }
        | Event::VoiceActivityChanged { .. }
        | Event::VoiceParticipantJoined { .. }
        | Event::VoiceParticipantLeft { .. }
        | Event::VoiceScreenShareChanged { .. }
        | Event::CallAudioChanged { .. }
        | Event::CallTranscriptChanged { .. }
        | Event::ModuleRoomChanged(_)
        // Durable so a lagging reader resyncs; the client fills a gap in `seq` over REST.
        | Event::CallTranscriptLine { .. }
        | Event::CallTranscriptMarkChanged { .. }
        | Event::CallRinging { .. }
        | Event::CallRingEnded { .. }
        | Event::DmChanged { .. }
        | Event::ReportsChanged
        | Event::AdminAlertsChanged
        // Private notices and read markers move no permission and need no fan-out ordering.
        | Event::ReadStateChanged { .. }
        | Event::NotificationOverrideChanged { .. }
        | Event::CategoryMuteChanged { .. }
        | Event::NewDeviceSignIn { .. }
        | Event::VoiceMoved { .. }
        | Event::VoiceRemoved { .. }
        | Event::VoiceNotice { .. }
        | Event::VoiceSessionClosed { .. } => false,
        Event::Stamped { event, .. } => is_ephemeral(event),
    }
}
