// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The wire frame for a channel-scoped event that `authorization` has cleared
//! for this viewer and that needs no store read to build.

use super::ChannelDto;
use super::frames::{PollOptionCountDto, ServerFrame};
use crate::http::link_preview::LinkPreviews;
use crate::hub::{CanvasEvent, Event, MessageEvent};

/// The frame for `event`, `None` for an event no channel frame carries, or the event
/// back when its frame is built per viewer from the store.
pub(super) fn to_frame(
    link_previews: &LinkPreviews,
    event: Event,
) -> Result<Option<ServerFrame>, Box<Event>> {
    Ok(Some(match event {
        per_viewer @ (Event::Message(MessageEvent::Created { .. })
        | Event::Message(MessageEvent::Edited { .. })
        | Event::Message(MessageEvent::ReactionsChanged { .. })) => {
            return Err(Box::new(per_viewer));
        }
        Event::Message(MessageEvent::Deleted {
            channel_id,
            message_id,
            op_seq,
        }) => ServerFrame::MessageDeleted {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            op_seq,
        },
        // No per-viewer derivation: the output is the same for everyone past `authorization::authorize_unstamped`'s VIEW_CHANNEL gate, so it is delivered as-is.
        Event::Message(MessageEvent::CodeRunChanged {
            channel_id,
            message_id,
            block_index,
            module_id,
            command,
            ok,
            output,
            ran_by,
            ran_at,
        }) => ServerFrame::CodeRunChanged {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            block_index,
            module_id,
            command,
            ok,
            output: output.to_string(),
            ran_by: ran_by.map(|u| u.to_string()),
            ran_at,
        },
        Event::Message(MessageEvent::CodeRunsCleared {
            channel_id,
            message_id,
        }) => ServerFrame::CodeRunsCleared {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
        },
        Event::Message(MessageEvent::ThreadUpdated {
            channel_id,
            parent_message_id,
            thread_channel_id,
            reply_count,
            last_reply_at,
        }) => ServerFrame::ThreadUpdated {
            channel_id: channel_id.to_string(),
            parent_message_id: parent_message_id.to_string(),
            thread_channel_id: thread_channel_id.to_string(),
            reply_count,
            last_reply_at,
        },
        Event::Message(MessageEvent::Pinned {
            channel_id,
            message_id,
            pinned_by,
            pinned_at,
        }) => ServerFrame::MessagePinned {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            pinned_by: pinned_by.map(|id| id.to_string()),
            pinned_at,
        },
        Event::Message(MessageEvent::Unpinned {
            channel_id,
            message_id,
        }) => ServerFrame::MessageUnpinned {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
        },
        Event::Message(MessageEvent::PollVoted {
            channel_id,
            message_id,
            options,
            runoff,
        }) => ServerFrame::PollVoted {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            options: options
                .into_iter()
                .map(|(position, votes)| PollOptionCountDto { position, votes })
                .collect(),
            runoff: runoff.map(Into::into),
        },
        Event::Message(MessageEvent::ComponentsChanged {
            channel_id,
            message_id,
            components,
        }) => ServerFrame::MessageComponentsChanged {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            components: (*components).clone(),
        },
        Event::Message(MessageEvent::EmbedsChanged {
            channel_id,
            message_id,
            embeds,
        }) => ServerFrame::MessageEmbedsChanged {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            embeds: crate::http::embeds::dtos_from_stored(link_previews, (*embeds).clone()),
        },
        Event::Message(MessageEvent::VoiceTranscript {
            channel_id,
            message_id,
            attachment_id,
            status,
            text,
        }) => ServerFrame::MessageVoiceTranscript {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            attachment_id,
            status,
            text,
        },
        Event::Message(MessageEvent::LinkPreviewsRemoved {
            channel_id,
            message_id,
            op_seq,
        }) => ServerFrame::MessageLinkPreviewsRemoved {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            op_seq,
        },
        Event::TypingStarted {
            channel_id,
            user_id,
        } => ServerFrame::TypingStarted {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
        },
        Event::TypingStopped {
            channel_id,
            user_id,
        } => ServerFrame::TypingStopped {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
        },
        // Cloned only here, past every filter in `authorize`; see `MessageEvent::Created`'s own note.
        Event::ChannelCreated(channel, restricted) => ServerFrame::ChannelCreated {
            channel: ChannelDto::with_restricted((*channel).clone(), restricted),
        },
        Event::ChannelUpdated(channel, restricted) => ServerFrame::ChannelUpdated {
            channel: ChannelDto::with_restricted((*channel).clone(), restricted),
        },
        Event::OverwriteChanged { channel_id, .. } => ServerFrame::OverwriteChanged {
            channel_id: channel_id.to_string(),
        },
        Event::VoiceActivityChanged { channel_id } => ServerFrame::VoiceActivityChanged {
            channel_id: channel_id.to_string(),
        },
        Event::VoiceParticipantJoined {
            channel_id,
            user_id,
        } => ServerFrame::VoiceParticipantJoined {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
        },
        Event::VoiceParticipantLeft {
            channel_id,
            user_id,
        } => ServerFrame::VoiceParticipantLeft {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
        },
        Event::VoiceScreenShareChanged {
            channel_id,
            user_id,
            is_sharing_screen,
        } => ServerFrame::VoiceScreenShareChanged {
            channel_id: channel_id.to_string(),
            user_id: user_id.to_string(),
            is_sharing_screen,
        },
        Event::CallAudioChanged {
            channel_id,
            state,
            ended,
        } => ServerFrame::VoiceCallAudio {
            channel_id: channel_id.to_string(),
            state,
            ended,
        },
        Event::ModuleRoomChanged(change) => ServerFrame::ModuleRoom {
            channel_id: change.channel_id.to_string(),
            module_id: change.module_id.clone(),
            seq: change.seq,
            state: change.state.clone(),
            scene: change.scene.clone(),
            ended: change.ended,
        },
        Event::CallTranscriptChanged {
            channel_id,
            transcript_id,
            ended,
        } => ServerFrame::VoiceCallTranscript {
            channel_id: channel_id.to_string(),
            transcript_id: transcript_id.to_string(),
            ended,
        },
        Event::CallTranscriptLine {
            channel_id,
            transcript_id,
            line,
            ..
        } => ServerFrame::CallTranscriptLine {
            channel_id: channel_id.to_string(),
            transcript_id: transcript_id.to_string(),
            line: (*line).clone().into(),
        },
        Event::WatchTick {
            channel_id,
            bot_user_id,
            ended,
            item_id,
            playing,
            position_ms,
            sampled_at_ms,
            epoch,
        } => ServerFrame::WatchTick {
            channel_id: channel_id.to_string(),
            bot_user_id: bot_user_id.to_string(),
            ended,
            item_id,
            playing,
            position_ms,
            sampled_at_ms,
            epoch,
        },
        Event::CallRinging {
            channel_id,
            ring_id,
            caller_id,
            ..
        } => ServerFrame::CallRinging {
            channel_id: channel_id.to_string(),
            ring_id: ring_id.to_string(),
            caller_id: caller_id.to_string(),
        },
        Event::CallRingEnded {
            channel_id,
            ring_id,
            outcome,
        } => ServerFrame::CallRingEnded {
            channel_id: channel_id.to_string(),
            ring_id: ring_id.to_string(),
            outcome: outcome.as_str().to_owned(),
        },
        Event::DmChanged { channel_id } => ServerFrame::DmChanged {
            channel_id: channel_id.to_string(),
        },
        // canvas_frames::to_frame already answered Ok for any of these.
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
        | Event::Canvas(CanvasEvent::ObjectLockChanged { .. })
        | Event::Canvas(CanvasEvent::TileSceneChanged { .. }) => {
            unreachable!("canvas_frames::to_frame")
        }
        // The deployment-wide and channel-deletion cases already answered by `deployment_frames::authorize`.
        Event::SessionRevoked(_)
        | Event::PresenceChanged(_)
        | Event::MemberTimeoutChanged { .. }
        | Event::JoinGateChanged { .. }
        | Event::MemberRemoved(_)
        | Event::MemberRestored(_)
        | Event::MemberJoined(_)
        | Event::OwnerChanged(_)
        | Event::ProfileChanged(_)
        | Event::BotUiChanged(_)
        | Event::RoleChanged { .. }
        | Event::MemberRoleChanged { .. }
        | Event::ChannelDeleted { .. }
        | Event::CategoryChanged
        | Event::SpaceSettingsChanged
        | Event::SpaceThemesChanged
        | Event::ReportsChanged
        | Event::AdminAlertsChanged
        | Event::ReadStateChanged { .. }
        | Event::NotificationOverrideChanged { .. }
        | Event::CategoryMuteChanged { .. }
        | Event::EphemeralMessage { .. }
        | Event::InteractionCreated { .. }
        | Event::InteractionAnswered { .. }
        | Event::ConnectorRun(_)
        | Event::InteractionForm { .. }
        | Event::NewDeviceSignIn { .. }
        | Event::VoiceMoved { .. }
        | Event::VoiceRemoved { .. }
        | Event::VoiceNotice { .. }
        | Event::SoundboardPlayed { .. }
        | Event::VoiceSessionClosed { .. }
        | Event::Stamped { .. } => return Ok(None),
    }))
}
