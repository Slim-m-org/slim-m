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
use crate::ids::{ChannelId, MessageId, UserId};
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
/// Events with no channel to check go first (`deployment_frames`); the rest
/// pass the view check, the canvas bit and the presence rules, in that order.
pub(super) async fn authorize_unstamped(
    store: &Store,
    hub: &Hub,
    link_previews: &LinkPreviews,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    event: Event,
) -> Authorization {
    let event = match super::deployment_frames::authorize(store, hub, ctx, event).await {
        Ok(decision) => return decision,
        Err(event) => *event,
    };
    let Some(channel_id) = super::channel_scope::channel_of(&event) else {
        return Authorization::Withhold;
    };
    // The one event whose subject may have just lost this very view.
    let held_it_before = matches!(
        &event,
        Event::OverwriteChanged { previously_visible_to, .. }
            if previously_visible_to.contains(&ctx.user_id)
    );
    let Some(permissions) = resolve_permissions(store, hub, ctx, cache, channel_id).await else {
        // Unresolved rather than remembered; see `Authorization::Unknown`.
        return Authorization::Unknown;
    };
    let visible = permissions.contains(Permissions::VIEW_CHANNEL);
    if !visible && !held_it_before {
        return Authorization::Withhold;
    }
    // The canvas frames are gated on a second bit, as their own read routes are; without this a denial is void here.
    if let Some(extra) = super::authorization_bits::extra_bit(&event)
        && !permissions.contains(extra)
    {
        return Authorization::Withhold;
    }
    if !passes_presence_gates(store, hub, ctx, &event).await {
        return Authorization::Withhold;
    }
    channel_frame(store, link_previews, ctx, event).await
}

/// This connection's permissions in `channel_id`, from the cache or the store, or `None` when the store could not answer.
async fn resolve_permissions(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    channel_id: ChannelId,
) -> Option<Permissions> {
    // Read before the query, never after; see `PermissionCache::insert`.
    let epoch = hub.permissions_epoch();
    match cache.get(channel_id, Instant::now(), epoch) {
        Some(cached) => Some(cached),
        None => {
            let resolved = match store.permissions_in_channel(ctx.user_id, channel_id).await {
                Ok(answer) => Ok(answer),
                // Retried once: the alternative is every connection dropping together.
                Err(_) => {
                    tokio::time::sleep(RESOLVE_RETRY_DELAY).await;
                    store.permissions_in_channel(ctx.user_id, channel_id).await
                }
            };
            let answer = resolved.ok()?;
            cache.insert(channel_id, answer, Instant::now(), epoch);
            Some(answer)
        }
    }
}

/// Whether the per-viewer presence rules let a typing or voice event through.
async fn passes_presence_gates(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    event: &Event,
) -> bool {
    // Typing leaks presence and must fail closed on a blip; canvas frames pass the view and canvas gates above, since a drawer on a shared canvas is already visible to it.
    if let Event::TypingStarted { user_id, .. } = *event {
        let confirmed_visible = matches!(
            signals::presence_status(store, hub, ctx.user_id, user_id).await,
            Ok(Some(status)) if status != crate::presence::Status::Offline
        );
        if !confirmed_visible {
            return false;
        }
    }

    // A stop fires after the typer may have left, so offline must not withhold it; only a chosen Hidden does.
    if let Event::TypingStopped { user_id, .. } = *event
        && !signals::may_hear_typing_stop(store, hub, ctx.user_id, user_id).await
    {
        return false;
    }

    // Gated on chosen VISIBILITY, not live connection; see decision 0032.
    if let Event::VoiceParticipantJoined { user_id, .. }
    | Event::VoiceParticipantLeft { user_id, .. }
    | Event::VoiceScreenShareChanged { user_id, .. } = *event
        && user_id != ctx.user_id
    {
        let hidden = matches!(
            store.presence_visibility(user_id).await,
            Ok(Some(crate::presence::Visibility::Hidden))
        );
        if hidden {
            return false;
        }
    }
    true
}

/// The wire frame for a channel-scoped event that has passed every check above.
async fn channel_frame(
    store: &Store,
    link_previews: &LinkPreviews,
    ctx: &SessionContext,
    event: Event,
) -> Authorization {
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
        } => match super::message_frames::edited(
            store,
            ctx.user_id,
            (*message).clone(),
            op_seq,
            forwarded.as_deref().cloned(),
        )
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
        } => match reactions_frame(store, ctx, channel_id, message_id, &reactors).await {
            Ok(frame) => frame,
            Err(()) => return Authorization::Unknown,
        },
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
            output: output.to_string(),
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
            runoff,
        } => ServerFrame::PollVoted {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            options: options
                .into_iter()
                .map(|(position, votes)| PollOptionCountDto { position, votes })
                .collect(),
            runoff: runoff.map(Into::into),
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
        Event::MessageEmbedsChanged {
            channel_id,
            message_id,
            embeds,
        } => ServerFrame::MessageEmbedsChanged {
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            embeds: super::super::embeds::dtos_from_stored(link_previews, (*embeds).clone()),
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
        | Event::CanvasObjectPreview { .. }
        | Event::CanvasObjectMoved { .. }
        | Event::CanvasObjectReordered { .. }
        | Event::CanvasMediaSlotChanged { .. }
        | Event::CanvasObjectLockChanged { .. } => unreachable!("canvas_frames::to_frame"),
        // The deployment-wide and channel-deletion cases already returned above.
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
        | Event::VoiceMoved { .. }
        | Event::Stamped { .. } => return Authorization::Withhold,
    }))
}

/// The reaction counts this viewer sees: blocked reactors left out, ordered by this viewer's own first reaction per emoji.
async fn reactions_frame(
    store: &Store,
    ctx: &SessionContext,
    channel_id: ChannelId,
    message_id: MessageId,
    reactors: &[(String, Vec<(UserId, i64)>)],
) -> Result<ServerFrame, ()> {
    let reactor_ids: Vec<_> = reactors
        .iter()
        .flat_map(|(_, entries)| entries.iter().map(|(id, _)| *id))
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect();
    let blocked = match store.blocked_among(ctx.user_id, &reactor_ids).await {
        Ok(blocked) => blocked,
        Err(_) => return Err(()),
    };
    // This viewer's own `first_at` per emoji, reduced only from unblocked reactors - same as the old `reactions_for_messages` query did.
    let mut visible: Vec<(String, i64, i64)> = reactors
        .iter()
        .filter_map(|(emoji, entries)| {
            let unblocked_at: Vec<i64> = entries
                .iter()
                .filter(|(id, _)| !blocked.contains(id))
                .map(|(_, created_at)| *created_at)
                .collect();
            let first_at = unblocked_at.iter().copied().min()?;
            Some((emoji.clone(), unblocked_at.len() as i64, first_at))
        })
        .collect();
    visible.sort_by(|a, b| a.2.cmp(&b.2).then_with(|| a.0.cmp(&b.0)));
    Ok(ServerFrame::ReactionsChanged {
        channel_id: channel_id.to_string(),
        message_id: message_id.to_string(),
        reactions: visible
            .into_iter()
            .map(|(emoji, count, _)| ReactionCountDto { emoji, count })
            .collect(),
    })
}
