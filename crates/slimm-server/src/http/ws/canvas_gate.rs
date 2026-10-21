// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Whether one connection may relay a canvas live frame, answered from the
//! connection's cache so a drawing pointer costs no queries per frame.

use std::time::Instant;

use super::permission_cache::PermissionCache;
use crate::hub::Hub;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::store::{SessionContext, Store, now_ms};

/// Which bar a frame has to clear.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Frame {
    /// A pointer position: view plus `USE_CANVAS`; a timeout freezes the pen, not the mouse.
    Pointer,
    /// Ink or a drag: the pointer bar and no timeout in force.
    Ink,
}

/// Fails closed on a store error, and never caches one.
pub(super) async fn may_relay(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    channel_id: ChannelId,
    frame: Frame,
) -> bool {
    relay_grant(store, hub, ctx, cache, channel_id, frame)
        .await
        .is_some()
}

/// [`may_relay`], handing back the channel permissions the answer rested on.
pub(super) async fn relay_grant(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    channel_id: ChannelId,
    frame: Frame,
) -> Option<Permissions> {
    // Read before any query, never after; see `PermissionCache::insert`.
    let epoch = hub.permissions_epoch();
    let now = Instant::now();
    let granted = match cache.get(channel_id, now, epoch) {
        Some(cached) => cached,
        None => match store.permissions_in_channel(ctx.user_id, channel_id).await {
            Ok(answer) => {
                cache.insert(channel_id, answer, now, epoch);
                answer
            }
            Err(_) => return None,
        },
    };
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS);
    if !granted.contains(needed) {
        return None;
    }
    if frame == Frame::Pointer {
        return Some(granted);
    }
    let until_ms = match cache.timeout_until(now, epoch) {
        Some(cached) => cached,
        None => match store.timed_out_until(ctx.user_id).await {
            Ok(answer) => {
                cache.insert_timeout(answer, now, epoch);
                answer
            }
            Err(_) => return None,
        },
    };
    until_ms
        .is_none_or(|until| now_ms() >= until)
        .then_some(granted)
}
