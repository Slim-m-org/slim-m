// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What everyone else's open views are told once an account is deleted, so a
//! cached tally, poll count, room name or author label does not outlive it.

use std::sync::Arc;

use crate::hub::{Event, MessageEvent};
use crate::ids::{ChannelId, MessageId, UserId};
use crate::store::DeletedAccount;

use super::super::AppState;

/// Newest messages announced per kind; anything older refreshes when it is next read.
const MAX_ANNOUNCED_MESSAGES: usize = 200;

/// Announces a finished deletion: the member gone, their profile changed, and
/// every reaction tally, poll and room it touched.
pub(in crate::http) async fn announce_deleted_account(
    state: &AppState,
    user_id: UserId,
    deleted: DeletedAccount,
) {
    super::announce_member_gone(state, user_id).await;
    // An evicted profile re-resolves to the tombstone, so cached author labels stop naming them.
    state.hub.publish(Event::ProfileChanged(user_id));
    for target in newest(deleted.reactions_changed) {
        if super::super::reactions::publish(state, target, None)
            .await
            .is_err()
        {
            tracing::warn!("could not announce a deleted account's reactions");
        }
    }
    for (channel_id, message_id) in newest(deleted.polls_changed) {
        match state.store.poll_outcome(message_id).await {
            Ok(Some(outcome)) => state.hub.publish(Event::Message(MessageEvent::PollVoted {
                channel_id,
                message_id,
                options: outcome.tally,
                runoff: outcome.runoff,
            })),
            Ok(None) => {}
            Err(err) => tracing::warn!(?err, "could not announce a deleted account's poll vote"),
        }
    }
    for room in deleted.rooms_renamed {
        if let Err(err) = announce_room(state, room).await {
            tracing::warn!(?err, "could not announce a deleted account's room");
        }
    }
    super::super::space_owner::announce_handoff(state, deleted.handoff);
}

async fn announce_room(state: &AppState, room: ChannelId) -> anyhow::Result<()> {
    let Some(channel) = state.store.channel(room).await? else {
        return Ok(());
    };
    let restricted = state.store.channel_restricted(room).await?;
    state
        .hub
        .publish(Event::ChannelUpdated(Arc::new(channel), restricted));
    Ok(())
}

/// UUIDv7 ids sort by creation, so the tail is what open views most likely show.
fn newest(mut items: Vec<(ChannelId, MessageId)>) -> Vec<(ChannelId, MessageId)> {
    items.sort_by_key(|(_, message_id)| *message_id);
    let skip = items.len().saturating_sub(MAX_ANNOUNCED_MESSAGES);
    items.split_off(skip)
}
