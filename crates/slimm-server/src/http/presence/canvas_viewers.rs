// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /presence/canvas-viewers`: who has each open board the caller can view, in one read.

use std::collections::HashSet;

use serde::Serialize;

use crate::http::AppState;
use crate::http::error::ApiError;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::presence::canvas_viewers::viewer_shown;
use crate::store::now_ms;

#[derive(Serialize)]
pub(super) struct ViewerDto {
    user_id: String,
    since: i64,
}

#[derive(Serialize)]
pub(super) struct BoardViewersDto {
    channel_id: String,
    viewers: Vec<ViewerDto>,
}

#[derive(Serialize)]
pub(super) struct CanvasViewersDto {
    channels: Vec<BoardViewersDto>,
}

/// Open boards the caller can view that have anyone shown on them, each viewer ordered by arrival.
pub(super) async fn snapshot(
    state: &AppState,
    caller: UserId,
) -> Result<CanvasViewersDto, ApiError> {
    let registry = state.hub.canvas_viewers();
    let busy = registry.open_channels();
    let mut channels = Vec::new();
    if busy.is_empty() {
        return Ok(CanvasViewersDto { channels });
    }
    let presence = state.hub.presence();
    let now = now_ms();
    let viewable = state
        .store
        .channels_where(caller, Permissions::VIEW_CHANNEL)
        .await?;
    let mut boards: Vec<ChannelId> = viewable
        .into_iter()
        .filter(|c| c.canvas_open() && busy.contains(&c.id))
        .map(|c| c.id)
        .collect();
    let dms = state.store.dm_channel_ids_for_user(caller).await?;
    boards.extend(dms.into_iter().filter(|id| busy.contains(id)));
    for channel_id in boards {
        let mut shown: Vec<(UserId, i64)> = registry
            .entries(channel_id)
            .into_iter()
            .filter(|(user, entry)| {
                *user == caller || viewer_shown(entry, presence.visibility(*user))
            })
            .map(|(user, _)| (user, registry.shown_since(user, channel_id).unwrap_or(now)))
            .collect();
        let others: Vec<UserId> = shown
            .iter()
            .map(|(user, _)| *user)
            .filter(|user| *user != caller)
            .collect();
        let kept: HashSet<UserId> = state
            .store
            .viewers_among(channel_id, &others)
            .await?
            .into_iter()
            .chain(std::iter::once(caller))
            .collect();
        shown.retain(|(user, _)| kept.contains(user));
        shown.sort_by_key(|(user, at)| (*at, user.to_string()));
        if shown.is_empty() {
            continue;
        }
        channels.push(BoardViewersDto {
            channel_id: channel_id.to_string(),
            viewers: shown
                .into_iter()
                .map(|(user, at)| ViewerDto {
                    user_id: user.to_string(),
                    since: at,
                })
                .collect(),
        });
    }
    Ok(CanvasViewersDto { channels })
}
