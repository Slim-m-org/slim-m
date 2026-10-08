// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-event, per-connection authorization: turning a fanned-out [`Event`]
//! into the wire frame one specific viewer may or may not be shown.
//!
//! Split out of `super` (the envelope and connection loop) to keep that file
//! focused on the socket lifecycle; this one owns the permission and
//! visibility decision itself.

use std::time::Instant;

use super::ChannelDto;
use super::frames::{PollOptionCountDto, ReactionCountDto, ServerFrame};
use super::permission_cache::PermissionCache;
use super::signals;
use crate::http::link_preview::LinkPreviews;
use crate::hub::{Event, Hub};
use crate::permissions::Permissions;
use crate::store::{SessionContext, Store};

/// The outcome of authorizing one event for one connection.
pub(super) enum Authorization {
    /// The event is cleared to go out as this frame. Boxed: `ServerFrame`'s
    /// largest variant otherwise makes every `Authorization`, including the
    /// two that carry nothing, pay for it.
    Deliver(Box<ServerFrame>),
    /// This user may not see the event; say nothing, same as if it never
    /// happened for them.
    Withhold,
    /// A store read needed to decide failed, so it is unknown whether this
    /// connection may see the event - not "no" the way `Withhold` is.
    /// Silently dropping it here would lose the event for good: `/sync`
    /// filters purely by seq and this connection's cursor has already moved
    /// past it, so only a full channel reset would ever recover it. The
    /// caller closes the connection instead, onto the same resync path a
    /// lagged subscriber already takes.
    Unknown,
}

/// How long to wait before the single retry of a failed permission read.
///
/// A store error here is not per-connection, it is per-*event*: every
/// connection that event would have reached hits it in the same instant, and
/// `Authorization::Unknown` closes each of them. The client's resync has no
/// backoff, so all of them re-run `/sync`, mint a ticket and reconnect at
/// once, against the database that just failed. This project has already seen
/// SQLITE_BUSY under concurrent load, which is exactly the transient a second
/// attempt turns back into a delivered frame. Short enough that a real
/// outage still gives up promptly.
const RESOLVE_RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(25);

/// The bit a frame needs beyond `VIEW_CHANNEL`, if any.
///
/// Exhaustive with no wildcard, so a new variant does not compile until
/// somebody classifies it - the same discipline `moves_permissions`
/// (`hub.rs`) already uses. Replaces a `matches!` naming one variant, which
/// would have shipped the next canvas event gated on `VIEW_CHANNEL` alone.
fn extra_bit(event: &Event) -> Option<Permissions> {
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

/// [`authorize_unstamped`], with a moderation event's number attached to the frame it delivers.
pub(super) async fn authorize(
    store: &Store,
    hub: &Hub,
    link_previews: &LinkPreviews,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    event: Event,
) -> Authorization {
    let (seq, event) = match event {
        Event::Stamped { seq, event } => (Some(seq), *event),
        other => (None, other),
    };
    match (
        authorize_unstamped(store, hub, link_previews, ctx, cache, event).await,
        seq,
    ) {
        (Authorization::Deliver(frame), Some(seq)) => {
            Authorization::Deliver(Box::new(frame.with_moderation_seq(seq)))
        }
        (outcome, _) => outcome,
    }
}

/// Filters an event down to a wire frame, or the reason it is not delivered.
///
/// Presence is handled up front rather than folded into the channel-scoped
/// match: it has no channel to check view permission against (it is
/// deployment-wide, like the member list) and needs the receiving connection's
/// own user id to resolve the right answer for it.
pub(super) async fn authorize_unstamped(
    store: &Store,
    hub: &Hub,
    link_previews: &LinkPreviews,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    event: Event,
) -> Authorization {
    // Ahead of the channel-scoped match below; see the note on this function.
    if let Event::PresenceChanged(target_id) = event {
        // A gone account and a store blip both mean silence here, unlike below.
        let Ok(Some(status)) = signals::presence_status(store, hub, ctx.user_id, target_id).await
        else {
            return Authorization::Withhold;
        };
        let frame = signals::presence_frame(hub, target_id, status);
        return Authorization::Deliver(Box::new(frame));
    }
    if let Some(decision) = super::account_frames::authorize(ctx, &event) {
        return decision;
    }
    if let Event::EphemeralMessage {
        recipient_id,
        message,
    } = &event
    {
        return super::ephemeral_frames::authorize(store, ctx, *recipient_id, message).await;
    }
    if let Some(decision) = super::interaction_frames::authorize(store, ctx, &event).await {
        return decision;
    }
    // Private to one account and never to the device that just signed in.
    if let Event::NewDeviceSignIn {
        user_id,
        device_id,
        device_name,
        client_kind,
        signed_in_at,
    } = event
    {
        return if user_id == ctx.user_id && device_id != ctx.device_id {
            Authorization::Deliver(Box::new(ServerFrame::NewDeviceSignIn {
                device_id: device_id.to_string(),
                device_name,
                client_kind,
                signed_in_at,
            }))
        } else {
            Authorization::Withhold
        };
    }
    // A security boundary, not a visibility nicety; see `Event::ReportsChanged`'s own doc for why a failed permission read withholds rather than delivers.
    if let Event::ReportsChanged = event {
        let is_moderator = matches!(
            store.base_permissions(ctx.user_id).await,
            Ok(permissions) if permissions.contains(Permissions::MANAGE_MESSAGES)
        );
        return if is_moderator {
            Authorization::Deliver(Box::new(ServerFrame::ReportsChanged))
        } else {
            Authorization::Withhold
        };
    }
    // Deployment-wide like presence, but with nothing per-viewer to resolve.
    match event {
        Event::MemberTimeoutChanged { user_id, until } => {
            return Authorization::Deliver(Box::new(ServerFrame::MemberTimeoutChanged {
                seq: None,
                user_id: user_id.to_string(),
                until,
            }));
        }
        Event::MemberRemoved(user_id) => {
            return Authorization::Deliver(Box::new(ServerFrame::MemberRemoved {
                seq: None,
                user_id: user_id.to_string(),
            }));
        }
        Event::MemberRestored(user_id) => {
            return Authorization::Deliver(Box::new(ServerFrame::MemberRestored {
                seq: None,
                user_id: user_id.to_string(),
            }));
        }
        Event::MemberJoined(user_id) => {
            return Authorization::Deliver(Box::new(ServerFrame::MemberJoined {
                user_id: user_id.to_string(),
            }));
        }
        Event::RoleChanged { role_id } => {
            return Authorization::Deliver(Box::new(ServerFrame::RoleChanged {
                seq: None,
                role_id: role_id.to_string(),
            }));
        }
        Event::MemberRoleChanged { user_id, role_id } => {
            return Authorization::Deliver(Box::new(ServerFrame::MemberRoleChanged {
                seq: None,
                user_id: user_id.to_string(),
                role_id: role_id.to_string(),
            }));
        }
        Event::ProfileChanged(user_id) => {
            return Authorization::Deliver(Box::new(ServerFrame::ProfileChanged {
                user_id: user_id.to_string(),
            }));
        }
        Event::BotUiChanged(bot_user_id) => {
            return Authorization::Deliver(Box::new(ServerFrame::BotUiChanged {
                bot_user_id: bot_user_id.to_string(),
            }));
        }
        Event::CategoryChanged => {
            return Authorization::Deliver(Box::new(ServerFrame::CategoryChanged));
        }
        _ => {}
    }

    // Special-cased; see `Event::ChannelDeleted`'s doc comment for why.
    if let Event::ChannelDeleted { channel_id } = event {
        let viewed = match store
            .viewed_channel_before_delete(ctx.user_id, channel_id)
            .await
        {
            Ok(viewed) => viewed,
            Err(_) => return Authorization::Unknown,
        };
        return if viewed {
            Authorization::Deliver(Box::new(ServerFrame::ChannelDeleted {
                channel_id: channel_id.to_string(),
            }))
        } else {
            Authorization::Withhold
        };
    }

    let channel_id = match super::canvas_frames::channel_id(&event) {
        Some(channel_id) => channel_id,
        None => match &event {
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
            | Event::CanvasObjectMoved { .. }
            | Event::CanvasObjectReordered { .. }
            | Event::CanvasMediaSlotChanged { .. }
            | Event::CanvasObjectLockChanged { .. } => unreachable!("canvas_frames::channel_id"),
            // Control events are handled in the loop; the rest already returned above.
            Event::SessionRevoked(_)
            | Event::PresenceChanged(_)
            | Event::MemberTimeoutChanged { .. }
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
            | Event::Stamped { .. } => return Authorization::Withhold,
        },
    };
    // The one event whose subject may have just lost this very view.
    let held_it_before = matches!(
        &event,
        Event::OverwriteChanged { previously_visible_to, .. }
            if previously_visible_to.contains(&ctx.user_id)
    );
    // Read before the query, never after; see `PermissionCache::insert`.
    let epoch = hub.permissions_epoch();
    let permissions = match cache.get(channel_id, Instant::now(), epoch) {
        Some(cached) => cached,
        None => {
            let resolved = match store.permissions_in_channel(ctx.user_id, channel_id).await {
                Ok(answer) => Ok(answer),
                // Retried once: the alternative is every connection dropping together.
                Err(_) => {
                    tokio::time::sleep(RESOLVE_RETRY_DELAY).await;
                    store.permissions_in_channel(ctx.user_id, channel_id).await
                }
            };
            match resolved {
                Ok(answer) => {
                    cache.insert(channel_id, answer, Instant::now(), epoch);
                    answer
                }
                // Unresolved rather than remembered; see `Authorization::Unknown`.
                Err(_) => return Authorization::Unknown,
            }
        }
    };
    let visible = permissions.contains(Permissions::VIEW_CHANNEL);
    if !visible && !held_it_before {
        return Authorization::Withhold;
    }
    // The canvas frames are gated on a second bit, as their own read routes are; without this a denial is void here.
    if let Some(extra) = extra_bit(&event)
        && !permissions.contains(extra)
    {
        return Authorization::Withhold;
    }

    // Typing, a cursor and a stroke preview all leak presence and must fail closed on a blip.
    if let Event::TypingStarted { user_id, .. }
    | Event::CanvasCursorMoved { user_id, .. }
    | Event::CanvasStrokePreview { user_id, .. } = event
    {
        let confirmed_visible = matches!(
            signals::presence_status(store, hub, ctx.user_id, user_id).await,
            Ok(Some(status)) if status != crate::presence::Status::Offline
        );
        if !confirmed_visible {
            return Authorization::Withhold;
        }
    }

    // A stop fires after the typer may have left, so offline must not withhold it; only a chosen Hidden does.
    if let Event::TypingStopped { user_id, .. } = event
        && !signals::may_hear_typing_stop(store, hub, ctx.user_id, user_id).await
    {
        return Authorization::Withhold;
    }

    // Gated on chosen VISIBILITY, not live connection; see decision 0032.
    if let Event::VoiceParticipantJoined { user_id, .. }
    | Event::VoiceParticipantLeft { user_id, .. }
    | Event::VoiceScreenShareChanged { user_id, .. } = event
        && user_id != ctx.user_id
    {
        let hidden = matches!(
            store.presence_visibility(user_id).await,
            Ok(Some(crate::presence::Visibility::Hidden))
        );
        if hidden {
            return Authorization::Withhold;
        }
    }

    let event = match super::canvas_frames::to_frame(event) {
        Ok(frame) => return Authorization::Deliver(Box::new(frame)),
        Err(event) => *event,
    };
    Authorization::Deliver(Box::new(match event {
        created @ Event::MessageCreated { .. } => {
            match super::message_frames::created_from_event(
                store,
                link_previews,
                ctx.user_id,
                created,
            )
            .await
            {
                Ok(frame) => frame,
                Err(()) => return Authorization::Unknown,
            }
        }
        Event::MessageEdited {
            message,
            op_seq,
            forwarded,
        } => match super::message_frames::edited(store, ctx.user_id, message, op_seq, forwarded)
            .await
        {
            Ok(frame) => frame,
            Err(()) => return Authorization::Unknown,
        },
        Event::MessageDeleted {
            channel_id,
            message_id,
            op_seq,
        } => ServerFrame::MessageDeleted {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            op_seq,
        },
        // A separate, fresh-per-event store read past the view check; see `Authorization::Unknown`.
        Event::ReactionsChanged {
            channel_id,
            message_id,
            reactors,
        } => {
            let reactor_ids: Vec<_> = reactors
                .iter()
                .flat_map(|(_, entries)| entries.iter().map(|(id, _)| *id))
                .collect::<std::collections::HashSet<_>>()
                .into_iter()
                .collect();
            let blocked = match store.blocked_among(ctx.user_id, &reactor_ids).await {
                Ok(blocked) => blocked,
                Err(_) => return Authorization::Unknown,
            };
            // This viewer's own `first_at` per emoji, reduced only from unblocked reactors - same as the old `reactions_for_messages` query did.
            let mut visible: Vec<(String, i64, i64)> = reactors
                .into_iter()
                .filter_map(|(emoji, entries)| {
                    let unblocked_at: Vec<i64> = entries
                        .into_iter()
                        .filter(|(id, _)| !blocked.contains(id))
                        .map(|(_, created_at)| created_at)
                        .collect();
                    let first_at = unblocked_at.iter().copied().min()?;
                    Some((emoji, unblocked_at.len() as i64, first_at))
                })
                .collect();
            visible.sort_by(|a, b| a.2.cmp(&b.2).then_with(|| a.0.cmp(&b.0)));
            ServerFrame::ReactionsChanged {
                channel_id: channel_id.to_string(),
                message_id: message_id.to_string(),
                reactions: visible
                    .into_iter()
                    .map(|(emoji, count, _)| ReactionCountDto { emoji, count })
                    .collect(),
            }
        }
        // No per-viewer derivation: the output is the same for everyone past the VIEW_CHANNEL gate above, so it is delivered as-is.
        Event::CodeRunChanged {
            channel_id,
            message_id,
            block_index,
            module_id,
            command,
            ok,
            output,
            ran_by,
            ran_at,
        } => ServerFrame::CodeRunChanged {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            block_index,
            module_id,
            command,
            ok,
            output,
            ran_by: ran_by.map(|u| u.to_string()),
            ran_at,
        },
        Event::CodeRunsCleared {
            channel_id,
            message_id,
        } => ServerFrame::CodeRunsCleared {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
        },
        Event::ThreadUpdated {
            channel_id,
            parent_message_id,
            thread_channel_id,
            reply_count,
            last_reply_at,
        } => ServerFrame::ThreadUpdated {
            channel_id: channel_id.to_string(),
            parent_message_id: parent_message_id.to_string(),
            thread_channel_id: thread_channel_id.to_string(),
            reply_count,
            last_reply_at,
        },
        Event::MessagePinned {
            channel_id,
            message_id,
            pinned_by,
            pinned_at,
        } => ServerFrame::MessagePinned {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            pinned_by: pinned_by.map(|id| id.to_string()),
            pinned_at,
        },
        Event::MessageUnpinned {
            channel_id,
            message_id,
        } => ServerFrame::MessageUnpinned {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
        },
        Event::PollVoted {
            channel_id,
            message_id,
            options,
        } => ServerFrame::PollVoted {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            options: options
                .into_iter()
                .map(|(position, votes)| PollOptionCountDto { position, votes })
                .collect(),
        },
        Event::MessageComponentsChanged {
            channel_id,
            message_id,
            components,
        } => ServerFrame::MessageComponentsChanged {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            components: (*components).clone(),
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
        // Cloned only here, past every filter above; see `MessageCreated`'s own note.
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
        // canvas_frames::to_frame already answered Ok for any of these.
        Event::CanvasObjectPlaced { .. }
        | Event::CanvasObjectsRemoved { .. }
        | Event::CanvasCleared { .. }
        | Event::CanvasObjectsRestored { .. }
        | Event::CanvasCursorMoved { .. }
        | Event::CanvasStrokePreview { .. }
        | Event::CanvasObjectMoved { .. }
        | Event::CanvasObjectReordered { .. }
        | Event::CanvasMediaSlotChanged { .. }
        | Event::CanvasObjectLockChanged { .. } => unreachable!("canvas_frames::to_frame"),
        // The deployment-wide and channel-deletion cases already returned above.
        Event::SessionRevoked(_)
        | Event::PresenceChanged(_)
        | Event::MemberTimeoutChanged { .. }
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
        | Event::Stamped { .. } => return Authorization::Withhold,
    }))
}
