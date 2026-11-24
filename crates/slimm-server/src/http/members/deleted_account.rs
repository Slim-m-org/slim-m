// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What everyone else's open views are told once an account is deleted, so a
//! cached tally, poll count, room name or author label does not outlive it.

use std::sync::Arc;

use crate::hub::{Event, MessageEvent};
use crate::ids::{ChannelId, MessageId, UserId};
use crate::store::Handoff;
use crate::store::{Cleared, ClosedAccount, DeletedAccount};

use super::super::AppState;

/// Newest messages announced per kind; anything older refreshes when it is next read.
const MAX_ANNOUNCED_MESSAGES: usize = 200;

/// How long a deletion waits for its clean-up before answering; a slower one announces on its own.
const CLEAR_WAIT: std::time::Duration = std::time::Duration::from_secs(1);

/// Everything a closed account is owed at once: its sockets closed, its files and module data
/// gone, the member announced as gone. The slow clean-up runs in a task that outlives the request.
pub(in crate::http) async fn finish_closed_account(
    state: &AppState,
    user_id: UserId,
    closed: ClosedAccount,
) {
    super::super::session_revocation::account_sessions_revoked(state, user_id, None);
    if let Err(err) = state.media.delete_avatar(&user_id.to_string()).await {
        tracing::warn!(error = %err, "failed to delete an account's avatar file");
    }
    if let Err(err) = state.media.delete_user_banner(&user_id.to_string()).await {
        tracing::warn!(error = %err, "failed to delete an account's banner file");
    }
    super::super::linked_accounts::purge_avatar_files(state, user_id).await;
    super::super::dock::purge_module_member_data(state, user_id).await;
    announce_closed_account(state, user_id, closed.handoff).await;
    let background = state.clone();
    let clear = tokio::spawn(async move {
        let cleared = background.store.clear_account(user_id).await;
        announce_cleared_account(&background, cleared).await;
    });
    let _ = tokio::time::timeout(CLEAR_WAIT, clear).await;
}

async fn announce_closed_account(state: &AppState, user_id: UserId, handoff: Option<Handoff>) {
    super::announce_member_gone(state, user_id, true).await;
    // An evicted profile re-resolves to the tombstone, so cached author labels stop naming them.
    state.hub.publish(Event::ProfileChanged(user_id));
    super::super::space_owner::announce_handoff(state, handoff);
}

/// Announces a finished deletion: the member gone, their profile changed, and
/// every reaction tally, poll and room it touched.
pub(in crate::http) async fn announce_deleted_account(
    state: &AppState,
    user_id: UserId,
    deleted: DeletedAccount,
) {
    announce_closed_account(state, user_id, deleted.handoff).await;
    announce_cleared_account(
        state,
        Cleared {
            reactions_changed: deleted.reactions_changed,
            polls_changed: deleted.polls_changed,
            rooms_renamed: deleted.rooms_renamed,
        },
    )
    .await;
}

async fn announce_cleared_account(state: &AppState, cleared: Cleared) {
    for target in newest(cleared.reactions_changed) {
        if super::super::reactions::publish(state, target, None)
            .await
            .is_err()
        {
            tracing::warn!("could not announce a deleted account's reactions");
        }
    }
    for (channel_id, message_id) in newest(cleared.polls_changed) {
        match state.store.poll_outcome(message_id).await {
            Ok(Some(outcome)) => state.hub.publish(Event::Message(MessageEvent::PollVoted {
                channel_id,
                message_id,
                options: outcome.tally,
                runoff: outcome.runoff,
                version: outcome.version,
                cast: None,
            })),
            Ok(None) => {}
            Err(err) => tracing::warn!(?err, "could not announce a deleted account's poll vote"),
        }
    }
    for room in cleared.rooms_renamed {
        if let Err(err) = announce_room(state, room).await {
            tracing::warn!(?err, "could not announce a deleted account's room");
        }
    }
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
