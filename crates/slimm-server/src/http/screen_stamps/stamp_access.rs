// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who may fetch a picture because it was stamped on a screen (decision 0121).
//!
//! Fetch only: nothing here is part of `may_link`, so seeing a stamp never lets anyone post it.

use super::super::AppState;
use super::super::reports::report_visible_in;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::store::{SCREEN_STAMP_TTL_MS, now_ms};

/// Whether `user` may fetch `sha256` through a stamp that shows it: for a day as its
/// sender, its target or someone in that call who can view the channel, and as a
/// moderator of a report the stamp is linked to. A failed lookup grants nothing.
pub(in crate::http) async fn may_fetch_stamp_picture(
    state: &AppState,
    user: UserId,
    sha256: &[u8],
) -> bool {
    let store = &state.store;
    let fresh_since = now_ms() - SCREEN_STAMP_TTL_MS;
    if store
        .stamp_party_since(sha256, user, fresh_since)
        .await
        .unwrap_or(false)
    {
        return true;
    }
    let reported = store
        .reported_stamp_channels(sha256)
        .await
        .unwrap_or_default();
    if !reported.is_empty() && moderates_reports(state, user, &reported).await {
        return true;
    }
    let fresh = store
        .stamp_channels_since(sha256, fresh_since)
        .await
        .unwrap_or_default();
    for channel_id in fresh {
        if in_call_and_sees(state, user, channel_id).await {
            return true;
        }
    }
    false
}

async fn in_call_and_sees(state: &AppState, user: UserId, channel_id: ChannelId) -> bool {
    let Ok(present) = state.voice.list_participants_shared(channel_id).await else {
        return false;
    };
    present.iter().any(|p| p.user_id == user)
        && state
            .store
            .has_permission(user, channel_id, Permissions::VIEW_CHANNEL)
            .await
            .unwrap_or(false)
}

/// The same bar the moderation queue sets for showing a report from one of these channels.
async fn moderates_reports(state: &AppState, user: UserId, channels: &[ChannelId]) -> bool {
    let base = state.store.base_permissions(user).await;
    if !base.is_ok_and(|p| p.contains(Permissions::MANAGE_MESSAGES)) {
        return false;
    }
    for channel_id in channels {
        if report_visible_in(state, user, *channel_id).await {
            return true;
        }
    }
    false
}
