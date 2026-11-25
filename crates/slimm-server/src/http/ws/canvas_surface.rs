// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Whether a connection may see a board's viewers: view of the channel and an open surface,
//! answered from the connection's cache so a warm answer costs no query.

use std::time::Instant;

use super::permission_cache::PermissionCache;
use crate::hub::Hub;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::store::{SessionContext, Store};

/// Whether the board is open, filed beside the permissions entry the caller just resolved; `None` on a store error, which is never cached.
pub(super) async fn board_open(
    store: &Store,
    hub: &Hub,
    cache: &mut PermissionCache,
    channel_id: ChannelId,
) -> Option<bool> {
    let epoch = hub.permissions_epoch();
    if let Some(cached) = cache.surface_open(channel_id, Instant::now(), epoch) {
        return Some(cached);
    }
    let open = store.channel_canvas_open(channel_id).await.ok()?;
    cache.insert_surface(channel_id, open, epoch);
    Some(open)
}

/// View of the channel plus an open board; fails closed on a store error.
pub(super) async fn may_view_open(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    channel_id: ChannelId,
) -> bool {
    let epoch = hub.permissions_epoch();
    let now = Instant::now();
    let granted = match cache.get(channel_id, now, epoch) {
        Some(cached) => cached,
        None => match store.permissions_in_channel(ctx.user_id, channel_id).await {
            Ok(answer) => {
                cache.insert(channel_id, answer, now, epoch);
                answer
            }
            Err(_) => return false,
        },
    };
    granted.contains(Permissions::VIEW_CHANNEL)
        && board_open(store, hub, cache, channel_id).await == Some(true)
}
