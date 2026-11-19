// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-event, per-connection authorization: turning a fanned-out [`Event`]
//! into the wire frame one specific viewer may or may not be shown.
//!
//! Split out of `super` (the envelope and connection loop) to keep that file
//! focused on the socket lifecycle; this one owns the permission and
//! visibility decision itself.

use std::time::Instant;

use super::frames::{ReactionCountDto, ServerFrame};
use super::permission_cache::PermissionCache;
use super::signals;
use crate::http::link_preview::LinkPreviews;
use crate::hub::{Event, Hub, MessageEvent};
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
/// Events with no channel to check go first (`deployment_frames`); the rest pass
/// the call roster, the view check, the extra bit and the presence rules, in that order.
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
    if let Event::CallTranscriptLine { audience, .. } = &event
        && !audience.contains(&ctx.user_id)
    {
        return Authorization::Withhold;
    }
    if let Event::CallRinging { callees, .. } = &event
        && !callees.contains(&ctx.user_id)
    {
        return Authorization::Withhold;
    }
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
    // Some frames need a second bit, as their own read routes do; without this a denial is void here.
    if let Some(extra) = super::authorization_bits::extra_bit(&event)
        && !permissions.contains(extra)
    {
        return Authorization::Withhold;
    }
    if !passes_presence_gates(store, hub, ctx, &event).await {
        return Authorization::Withhold;
    }
    channel_frame(store, hub, link_previews, ctx, cache, event).await
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
            signals::visibility_of(store, hub, user_id).await,
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
    hub: &Hub,
    link_previews: &LinkPreviews,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    event: Event,
) -> Authorization {
    let mut event = match super::canvas_frames::to_frame(event) {
        Ok(frame) => return Authorization::Deliver(Box::new(frame)),
        Err(event) => *event,
    };
    if let Event::CallAudioChanged {
        state: Some(view), ..
    } = &mut event
    {
        view.hide_hidden(store, hub, ctx.user_id).await;
    }
    let event = match super::channel_frames::to_frame(link_previews, event) {
        Ok(Some(frame)) => return Authorization::Deliver(Box::new(frame)),
        Ok(None) => return Authorization::Withhold,
        Err(event) => *event,
    };
    let frame = match event {
        created @ Event::Message(MessageEvent::Created { .. }) => {
            super::message_frames::created_from_event(store, link_previews, ctx.user_id, created)
                .await
        }
        Event::Message(MessageEvent::Edited {
            message,
            op_seq,
            forwarded,
            lookups,
        }) => {
            super::message_frames::edited(
                store,
                ctx.user_id,
                (*message).clone(),
                op_seq,
                forwarded.as_deref().cloned(),
                &lookups,
            )
            .await
        }
        // A separate, fresh-per-event store read past the view check; see `Authorization::Unknown`.
        Event::Message(MessageEvent::ReactionsChanged {
            channel_id,
            message_id,
            reactors,
            ..
        }) => reactions_frame(store, hub, ctx, cache, (channel_id, message_id), &reactors).await,
        _ => unreachable!("channel_frames::to_frame answers every other event"),
    };
    match frame {
        Ok(frame) => Authorization::Deliver(Box::new(frame)),
        Err(()) => Authorization::Unknown,
    }
}

/// The reaction counts this viewer sees: blocked reactors left out, ordered by this viewer's own first reaction per emoji.
async fn reactions_frame(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    (channel_id, message_id): (ChannelId, MessageId),
    reactors: &[(String, Vec<(UserId, i64)>)],
) -> Result<ServerFrame, ()> {
    let blocked = viewer_blocks(store, hub, ctx, cache).await?;
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

/// Who this viewer has blocked, from the connection's cache or else the store.
async fn viewer_blocks<'a>(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &'a mut PermissionCache,
) -> Result<&'a std::collections::HashSet<UserId>, ()> {
    let now = Instant::now();
    // Read before the query, never after; see `PermissionCache::insert_blocked`.
    let epoch = hub.blocks_epoch();
    if cache.blocked(now, epoch).is_none() {
        let ids = store.blocked_ids(ctx.user_id).await.map_err(|_| ())?;
        cache.insert_blocked(ids, now, epoch);
    }
    cache.blocked(now, epoch).ok_or(())
}
