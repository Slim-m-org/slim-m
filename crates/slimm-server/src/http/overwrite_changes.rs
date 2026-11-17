// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who an overwrite write affects and could already view each channel it changes, resolved
//! before it lands, and the `OverwriteChanged` per channel after; a lobby's rooms change with it.

use std::sync::Arc;

use super::AppState;
use super::error::ApiError;
use super::overwrites::Target;
use crate::hub::Event;
use crate::ids::{ChannelId, RoleId, UserId};

/// Each of `channels` and every live room following one of them (decision 0065), with who
/// `targets` affect there and could already view it.
pub(super) async fn visible_before(
    state: &AppState,
    channels: &[ChannelId],
    targets: &[Target],
) -> Result<Vec<(ChannelId, Vec<UserId>)>, ApiError> {
    let mut out = Vec::with_capacity(channels.len());
    for &channel in channels {
        out.push((channel, viewers_among(state, channel, targets).await?));
        for room in state.store.live_rooms_of(channel).await? {
            // The copy replaces every row a room holds, any edit of its own included.
            let mut room_targets = targets.to_vec();
            for o in state.store.channel_overwrites(room).await? {
                room_targets.push(target_of(&o.target_type, o.target_id));
            }
            out.push((room, viewers_among(state, room, &room_targets).await?));
        }
    }
    Ok(out)
}

async fn viewers_among(
    state: &AppState,
    channel: ChannelId,
    targets: &[Target],
) -> Result<Vec<UserId>, ApiError> {
    let mut users = Vec::new();
    for target in targets {
        users.extend(previously_visible_to(state, channel, *target).await?);
    }
    users.sort();
    users.dedup();
    Ok(users)
}

pub(super) fn publish_changed(state: &AppState, before: Vec<(ChannelId, Vec<UserId>)>) {
    for (channel_id, previously_visible_to) in before {
        state.hub.publish(Event::OverwriteChanged {
            channel_id,
            previously_visible_to: Arc::new(previously_visible_to),
        });
    }
}

/// Who this overwrite affects and could already view the channel, resolved
/// before the write lands.
///
/// See [`Event::OverwriteChanged`] for why the event needs it: the ordinary
/// per-viewer check runs after the change, so the people whose access it just
/// removed are exactly the ones it would exclude.
async fn previously_visible_to(
    state: &AppState,
    channel_id: ChannelId,
    target: Target,
) -> Result<Vec<UserId>, ApiError> {
    let affected = match target {
        Target::Member(user_id) => vec![user_id],
        Target::Role(role_id) => match state.store.role(role_id).await? {
            // `@everyone` has no `member_roles` rows; it applies to every live member.
            Some(role) if role.is_everyone => state.store.all_live_user_ids().await?,
            _ => state.store.members_with_role(role_id).await?,
        },
    };
    Ok(state.store.viewers_among(channel_id, &affected).await?)
}

/// The target a stored overwrite row names.
pub(super) fn target_of(kind: &str, id: uuid::Uuid) -> Target {
    match kind {
        "member" => Target::Member(UserId(id)),
        _ => Target::Role(RoleId(id)),
    }
}
