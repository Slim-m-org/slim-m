// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Telling opted-in members that a call started, grew or went live (decision 0107).
//!
//! Detached from the webhook delivery: LiveKit retries anything slow, and a notice that fails
//! must not turn a join into a retry.

use std::collections::HashSet;

use super::super::AppState;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::push::VoiceNotice;
use crate::store::now_ms;
use crate::voice_notify::{self, Activity};

/// The join that opens a call, or one into a call already under way.
pub(super) fn join_activity(present_before: &[UserId], joiner: UserId) -> Activity {
    if present_before.iter().all(|user| *user == joiner) {
        Activity::CallStarted
    } else {
        Activity::Joined
    }
}

/// Works out who to tell and tells them, off the caller's task.
pub(super) fn announce(state: &AppState, channel_id: ChannelId, actor: UserId, activity: Activity) {
    let present = state.voice.live_state().present(channel_id);
    let state = state.clone();
    tokio::spawn(async move {
        if let Err(err) = run(&state, channel_id, actor, activity, &present).await {
            tracing::warn!(%err, %channel_id, "could not announce voice activity");
        }
    });
}

async fn run(
    state: &AppState,
    channel_id: ChannelId,
    actor: UserId,
    activity: Activity,
    present: &[UserId],
) -> anyhow::Result<()> {
    let now_ms = now_ms();
    let audience = voice_notify::audience(
        &state.store,
        &voice_notify::Event {
            channel_id,
            actor,
            activity,
            present,
            now_ms,
        },
    )
    .await?;
    if audience.is_empty() {
        return Ok(());
    }

    let reachable = reachable(state, &audience).await?;
    let windows = state.voice.notice_windows();
    let told: Vec<UserId> = audience
        .into_iter()
        .filter(|user| reachable.contains(user))
        .filter(|user| windows.claim(channel_id, *user, now_ms).is_some())
        .collect();
    if told.is_empty() {
        return Ok(());
    }
    for user_id in &told {
        state.hub.publish(Event::VoiceNotice {
            user_id: *user_id,
            channel_id,
            actor_id: actor,
            activity,
        });
    }
    state.push.notify_voice_activity(
        state.store.clone(),
        VoiceNotice {
            channel_id,
            actor_id: actor,
            activity,
            recipients: told,
        },
    );
    Ok(())
}

/// Who a notice could reach at all: connected now, or holding a push device the relay serves.
/// A window is only spent on someone it can reach.
async fn reachable(state: &AppState, audience: &[UserId]) -> anyhow::Result<HashSet<UserId>> {
    let presence = state.hub.presence();
    let mut reachable: HashSet<UserId> = audience
        .iter()
        .copied()
        .filter(|user| presence.is_connected(*user))
        .collect();
    if state.push.is_enabled() {
        let wanted: HashSet<UserId> = audience.iter().copied().collect();
        reachable.extend(
            state
                .store
                .users_with_push_devices()
                .await?
                .into_iter()
                .filter(|user| wanted.contains(user)),
        );
    }
    Ok(reachable)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_join_into_an_empty_call_starts_it() {
        let joiner = UserId::generate();
        assert_eq!(join_activity(&[], joiner), Activity::CallStarted);
        assert_eq!(join_activity(&[joiner], joiner), Activity::CallStarted);
    }

    #[test]
    fn a_join_beside_someone_else_is_just_a_join() {
        assert_eq!(
            join_activity(&[UserId::generate()], UserId::generate()),
            Activity::Joined
        );
    }
}
