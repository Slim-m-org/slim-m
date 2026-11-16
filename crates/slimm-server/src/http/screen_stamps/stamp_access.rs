// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who may fetch a picture because it was stamped on a screen (decision 0121).
//!
//! Fetch only: nothing here is part of `may_link`, so seeing a stamp never lets anyone post it.

use std::collections::HashSet;

use super::super::AppState;
use super::super::reports::report_visible_in;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::store::{SCREEN_STAMP_TTL_MS, ScreenStamp, now_ms};

/// Whether `user` may fetch `sha256` through a stamp that shows it: for a day as its
/// sender, its target or someone in that call who can view the channel, and as a
/// moderator of a report the stamp is linked to. A failed lookup grants nothing.
pub(in crate::http) async fn may_fetch_stamp_picture(
    state: &AppState,
    user: UserId,
    sha256: &[u8],
) -> bool {
    let Ok(stamps) = state.store.screen_stamps_for_sha(sha256).await else {
        return false;
    };
    let fresh_since = now_ms() - SCREEN_STAMP_TTL_MS;
    let mut asked = HashSet::new();
    for stamp in &stamps {
        let fresh = stamp.created_at >= fresh_since;
        if fresh && (stamp.target_id == user || stamp.sender_id == user) {
            return true;
        }
        if stamp.report_id.is_some() && moderates(state, user, stamp.channel_id).await {
            return true;
        }
        if fresh && asked.insert(stamp.channel_id) && in_call_and_sees(state, user, stamp).await {
            return true;
        }
    }
    false
}

async fn in_call_and_sees(state: &AppState, user: UserId, stamp: &ScreenStamp) -> bool {
    let Ok(present) = state.voice.list_participants_shared(stamp.channel_id).await else {
        return false;
    };
    present.iter().any(|p| p.user_id == user)
        && state
            .store
            .has_permission(user, stamp.channel_id, Permissions::VIEW_CHANNEL)
            .await
            .unwrap_or(false)
}

/// The same bar the moderation queue sets for showing a report from this channel.
async fn moderates(state: &AppState, user: UserId, channel_id: ChannelId) -> bool {
    let base = state.store.base_permissions(user).await;
    base.is_ok_and(|p| p.contains(Permissions::MANAGE_MESSAGES))
        && report_visible_in(state, user, channel_id).await
}
