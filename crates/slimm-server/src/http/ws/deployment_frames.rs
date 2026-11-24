// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Events decided before any channel permission is read: deployment-wide
//! ones, and ones with a per-viewer rule of their own.
//!
//! Presence comes first: it has no channel to check view permission against
//! and needs the receiving connection's own user id to resolve its answer.

use super::authorization::Authorization;
use super::frames::ServerFrame;
use super::permission_cache::PermissionCache;
use super::signals;
use std::time::Instant;

use crate::hub::{CanvasEvent, Event, Hub, RoleChange};
use crate::permissions::Permissions;
use crate::store::{SessionContext, Store};

/// The decision for an event this file owns, or the event handed back for the channel-scoped path.
pub(super) async fn authorize(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    event: Event,
) -> Result<Authorization, Box<Event>> {
    if connector_withholds(ctx, &event) {
        return Ok(Authorization::Withhold);
    }
    if let Event::PresenceChanged(change) = event {
        // A gone account and a store blip both mean silence here, unlike below.
        let Ok(Some(status)) = signals::change_status(store, hub, ctx.user_id, &change).await
        else {
            return Ok(Authorization::Withhold);
        };
        let frame = signals::presence_frame(hub, change.user_id, status);
        return Ok(Authorization::Deliver(Box::new(frame)));
    }
    if let Some(decision) = super::account_frames::authorize(ctx, &event) {
        return Ok(decision);
    }
    // Only the call it was drawn in hears a screen annotation; the canvas gates still apply to them.
    if let Event::Canvas(CanvasEvent::ScreenAnnotation(annotation)) = &event
        && !annotation.audience.contains(&ctx.user_id)
    {
        return Ok(Authorization::Withhold);
    }
    if let Event::EphemeralMessage {
        recipient_id,
        message,
    } = &event
    {
        return Ok(super::ephemeral_frames::authorize(store, ctx, *recipient_id, message).await);
    }
    if let Some(decision) = super::interaction_frames::authorize(store, ctx, &event).await {
        return Ok(decision);
    }
    match event {
        // Private to one account and never to the device that just signed in.
        Event::NewDeviceSignIn {
            user_id,
            device_id,
            device_name,
            client_kind,
            signed_in_at,
        } => Ok(if user_id == ctx.user_id && device_id != ctx.device_id {
            Authorization::Deliver(Box::new(ServerFrame::NewDeviceSignIn {
                device_id: device_id.to_string(),
                device_name,
                client_kind,
                signed_in_at,
            }))
        } else {
            Authorization::Withhold
        }),
        Event::ReportsChanged => Ok(reports_changed(store, hub, ctx, cache).await),
        Event::AdminAlertsChanged => Ok(admin_alerts_changed(store, hub, ctx, cache).await),
        Event::ChannelDeleted { channel_id } => {
            // Special-cased; see `Event::ChannelDeleted`'s doc comment for why.
            Ok(
                match store
                    .viewed_channel_before_delete(ctx.user_id, channel_id)
                    .await
                {
                    Ok(true) => Authorization::Deliver(Box::new(ServerFrame::ChannelDeleted {
                        channel_id: channel_id.to_string(),
                    })),
                    Ok(false) => Authorization::Withhold,
                    Err(_) => Authorization::Unknown,
                },
            )
        }
        other => broadcast_frame(other).map(|frame| Authorization::Deliver(Box::new(frame))),
    }
}

/// A connector's socket gets what its token could read over REST: never presence, and the
/// member directory only with `VIEW_CHANNEL` approved (see `http::connector_gate`).
fn connector_withholds(ctx: &SessionContext, event: &Event) -> bool {
    let Some(grant) = ctx.connector else {
        return false;
    };
    match event {
        Event::PresenceChanged(_) => true,
        Event::MemberTimeoutChanged { .. }
        | Event::JoinGateChanged { .. }
        | Event::MemberRemoved { .. }
        | Event::MemberRestored(_)
        | Event::MemberJoined(_)
        | Event::OwnerChanged(_)
        | Event::RoleChanged { .. }
        | Event::MemberRoleChanged { .. }
        | Event::ProfileChanged(_) => {
            !grant.enabled || !grant.cap.contains(Permissions::VIEW_CHANNEL)
        }
        _ => false,
    }
}

/// The connection's base permissions from the cache or the store; a store error is `None` and is never cached.
async fn cached_base_permissions(
    hub: &Hub,
    cache: &mut PermissionCache,
    load: impl std::future::Future<Output = anyhow::Result<Permissions>>,
) -> Option<Permissions> {
    // Read before the query, never after; see `PermissionCache::insert`.
    let epoch = hub.permissions_epoch();
    if let Some(cached) = cache.base(Instant::now(), epoch) {
        return Some(cached);
    }
    let answer = load.await.ok()?;
    cache.insert_base(answer, Instant::now(), epoch);
    Some(answer)
}

/// A security boundary, not a visibility nicety; see `Event::ReportsChanged`'s own doc for why a failed permission read withholds rather than delivers.
async fn reports_changed(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
) -> Authorization {
    let permissions =
        cached_base_permissions(hub, cache, store.base_permissions(ctx.user_id)).await;
    if permissions.is_some_and(|p| p.contains(Permissions::MANAGE_MESSAGES)) {
        Authorization::Deliver(Box::new(ServerFrame::ReportsChanged))
    } else {
        Authorization::Withhold
    }
}

/// Same boundary as [`reports_changed`], one permission up, and a mute withholds it too.
async fn admin_alerts_changed(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
) -> Authorization {
    let permissions =
        cached_base_permissions(hub, cache, store.base_permissions(ctx.user_id)).await;
    if !permissions.is_some_and(|p| p.contains(Permissions::MANAGE_SERVER)) {
        return Authorization::Withhold;
    }
    if store.admin_alerts_muted(ctx.user_id).await.unwrap_or(true) {
        Authorization::Withhold
    } else {
        Authorization::Deliver(Box::new(ServerFrame::AdminAlertsChanged))
    }
}

/// Deployment-wide like presence, but with nothing per-viewer to resolve.
fn broadcast_frame(event: Event) -> Result<ServerFrame, Box<Event>> {
    Ok(match event {
        Event::MemberTimeoutChanged { user_id, until } => ServerFrame::MemberTimeoutChanged {
            seq: None,
            user_id: user_id.to_string(),
            until,
        },
        Event::JoinGateChanged { user_id } => ServerFrame::JoinGateChanged {
            user_id: user_id.map(|id| id.to_string()),
        },
        Event::MemberRemoved { user_id, deleted } => ServerFrame::MemberRemoved {
            seq: None,
            user_id: user_id.to_string(),
            deleted,
        },
        Event::MemberRestored(user_id) => ServerFrame::MemberRestored {
            seq: None,
            user_id: user_id.to_string(),
        },
        Event::MemberJoined(user_id) => ServerFrame::MemberJoined {
            user_id: user_id.to_string(),
        },
        Event::OwnerChanged(user_id) => ServerFrame::OwnerChanged {
            user_id: user_id.to_string(),
        },
        Event::RoleChanged { role_id, change } => ServerFrame::RoleChanged {
            seq: None,
            role_id: role_id.to_string(),
            change: change.as_deref().map(RoleChange::kind),
            name: change
                .as_deref()
                .and_then(|c| c.after().or(c.before()))
                .map(|look| look.name.clone()),
            before: change.as_deref().and_then(|c| c.before().cloned()),
            after: change.as_deref().and_then(|c| c.after().cloned()),
        },
        Event::MemberRoleChanged {
            user_id,
            role_id,
            granted,
            role_name,
        } => ServerFrame::MemberRoleChanged {
            seq: None,
            user_id: user_id.to_string(),
            role_id: role_id.to_string(),
            granted,
            role_name,
        },
        Event::ProfileChanged(user_id) => ServerFrame::ProfileChanged {
            user_id: user_id.to_string(),
        },
        Event::BotUiChanged(bot_user_id) => ServerFrame::BotUiChanged {
            bot_user_id: bot_user_id.to_string(),
        },
        Event::CategoryChanged => ServerFrame::CategoryChanged,
        Event::SpaceSettingsChanged => ServerFrame::SpaceSettingsChanged,
        Event::SpaceThemesChanged => ServerFrame::SpaceThemesChanged,
        other => return Err(Box::new(other)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[tokio::test]
    async fn a_burst_of_events_reads_base_permissions_once_per_epoch() {
        let hub = Hub::new();
        let mut cache = PermissionCache::new();
        let reads = AtomicUsize::new(0);
        for _ in 0..30 {
            let load = async {
                reads.fetch_add(1, Ordering::Relaxed);
                Ok(Permissions::MANAGE_MESSAGES)
            };
            let got = cached_base_permissions(&hub, &mut cache, load).await;
            assert_eq!(got, Some(Permissions::MANAGE_MESSAGES));
        }
        assert_eq!(reads.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn a_failed_read_is_not_cached_and_withholds() {
        let hub = Hub::new();
        let mut cache = PermissionCache::new();
        let failed =
            cached_base_permissions(&hub, &mut cache, async { Err(anyhow::anyhow!("busy")) });
        assert_eq!(failed.await, None);
        let again = cached_base_permissions(&hub, &mut cache, async { Ok(Permissions::NONE) });
        assert_eq!(again.await, Some(Permissions::NONE));
    }
}
