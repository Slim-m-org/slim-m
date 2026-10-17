// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Events decided before any channel permission is read: deployment-wide
//! ones, and ones with a per-viewer rule of their own.
//!
//! Presence comes first: it has no channel to check view permission against
//! and needs the receiving connection's own user id to resolve its answer.

use super::authorization::Authorization;
use super::frames::ServerFrame;
use super::signals;
use crate::hub::{Event, Hub};
use crate::permissions::Permissions;
use crate::store::{SessionContext, Store};

/// The decision for an event this file owns, or the event handed back for the channel-scoped path.
pub(super) async fn authorize(
    store: &Store,
    hub: &Hub,
    ctx: &SessionContext,
    event: Event,
) -> Result<Authorization, Box<Event>> {
    if let Event::PresenceChanged(target_id) = event {
        // A gone account and a store blip both mean silence here, unlike below.
        let Ok(Some(status)) = signals::presence_status(store, hub, ctx.user_id, target_id).await
        else {
            return Ok(Authorization::Withhold);
        };
        let frame = signals::presence_frame(hub, target_id, status);
        return Ok(Authorization::Deliver(Box::new(frame)));
    }
    if let Some(decision) = super::account_frames::authorize(ctx, &event) {
        return Ok(decision);
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
        Event::ReportsChanged => Ok(reports_changed(store, ctx).await),
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

/// A security boundary, not a visibility nicety; see `Event::ReportsChanged`'s own doc for why a failed permission read withholds rather than delivers.
async fn reports_changed(store: &Store, ctx: &SessionContext) -> Authorization {
    let is_moderator = matches!(
        store.base_permissions(ctx.user_id).await,
        Ok(permissions) if permissions.contains(Permissions::MANAGE_MESSAGES)
    );
    if is_moderator {
        Authorization::Deliver(Box::new(ServerFrame::ReportsChanged))
    } else {
        Authorization::Withhold
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
        Event::MemberRemoved(user_id) => ServerFrame::MemberRemoved {
            seq: None,
            user_id: user_id.to_string(),
        },
        Event::MemberRestored(user_id) => ServerFrame::MemberRestored {
            seq: None,
            user_id: user_id.to_string(),
        },
        Event::MemberJoined(user_id) => ServerFrame::MemberJoined {
            user_id: user_id.to_string(),
        },
        Event::RoleChanged { role_id } => ServerFrame::RoleChanged {
            seq: None,
            role_id: role_id.to_string(),
        },
        Event::MemberRoleChanged { user_id, role_id } => ServerFrame::MemberRoleChanged {
            seq: None,
            user_id: user_id.to_string(),
            role_id: role_id.to_string(),
        },
        Event::ProfileChanged(user_id) => ServerFrame::ProfileChanged {
            user_id: user_id.to_string(),
        },
        Event::BotUiChanged(bot_user_id) => ServerFrame::BotUiChanged {
            bot_user_id: bot_user_id.to_string(),
        },
        Event::CategoryChanged => ServerFrame::CategoryChanged,
        other => return Err(Box::new(other)),
    })
}
