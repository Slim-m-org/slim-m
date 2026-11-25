// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which canvases one connection has open, so a live cursor, preview or followed
//! view is only sent to a socket that can draw it.

use std::collections::HashSet;

use super::canvas_surface::may_view_open;
use super::permission_cache::PermissionCache;
use crate::hub::{CanvasEvent, Event, Hub};
use crate::ids::{ChannelId, UserId};
use crate::ratelimit::{Class, RateLimiter};
use crate::store::{SessionContext, Store, now_ms};

/// More than a person has open at once; the rest of a report is ignored.
const MAX_WATCHED_CANVASES: usize = 8;

/// What one declaration needs beyond the connection's own state.
pub(super) struct WatchEnv<'a> {
    pub(super) store: &'a Store,
    pub(super) hub: &'a Hub,
    pub(super) limiter: &'a RateLimiter,
    pub(super) ctx: &'a SessionContext,
    pub(super) connection: u64,
}

/// A connection's declared canvases. It starts undeclared and then delivers every
/// channel, so a client that predates `canvas.watch` keeps today's behaviour.
#[derive(Default)]
pub(super) struct CanvasWatch {
    declared: Option<HashSet<ChannelId>>,
}

impl CanvasWatch {
    /// Replaces the report and the connection's registered viewing.
    ///
    /// The pointer filter always takes the whole report. Removals always apply; an addition is
    /// registered only when the user's declaration budget allows and the channel's board is open
    /// to them, so a flood can neither plant viewers nor strand ghosts. Publishing is the flush's job.
    pub(super) async fn declare(
        &mut self,
        env: &WatchEnv<'_>,
        cache: &mut PermissionCache,
        channel_ids: &[String],
    ) {
        let wanted: HashSet<ChannelId> = channel_ids
            .iter()
            .take(MAX_WATCHED_CANVASES)
            .filter_map(|raw| uuid::Uuid::parse_str(raw).ok())
            .map(ChannelId)
            .collect();
        let viewers = env.hub.canvas_viewers();
        let registered = viewers.channels_of(env.connection);
        let mut next: HashSet<ChannelId> = wanted.intersection(&registered).copied().collect();
        let additions: Vec<ChannelId> = wanted.difference(&registered).copied().collect();
        let allowed = !additions.is_empty()
            && env
                .limiter
                .check(Class::CanvasWatch, &format!("u:{}", env.ctx.user_id));
        if allowed {
            for channel_id in additions {
                if may_view_open(env.store, env.hub, env.ctx, cache, channel_id).await {
                    next.insert(channel_id);
                }
            }
        }
        viewers.replace(env.ctx.user_id, env.connection, next, now_ms());
        self.declared = Some(wanted);
    }

    /// Whether an ephemeral canvas frame is worth sending to this connection.
    /// Every other event passes: only the pointer-rate frames are filtered, and
    /// a summon is not one of them, being a one-off request meant for everyone.
    pub(super) fn admits(&self, event: &Event, viewer: UserId) -> bool {
        let Some((channel_id, sender)) = ephemeral_canvas_origin(event) else {
            return true;
        };
        // Every client drops its own user's frames, and the sender already drew it.
        if sender == viewer {
            return false;
        }
        self.declared
            .as_ref()
            .is_none_or(|watched| watched.contains(&channel_id))
    }
}

fn ephemeral_canvas_origin(event: &Event) -> Option<(ChannelId, UserId)> {
    match event {
        Event::Canvas(CanvasEvent::CursorMoved {
            channel_id,
            user_id,
            ..
        })
        | Event::Canvas(CanvasEvent::StrokePreview {
            channel_id,
            user_id,
            ..
        })
        | Event::Canvas(CanvasEvent::ObjectPreview {
            channel_id,
            user_id,
            ..
        })
        | Event::Canvas(CanvasEvent::MediaSlotPreview {
            channel_id,
            user_id,
            ..
        })
        | Event::Canvas(CanvasEvent::View {
            channel_id,
            user_id,
            summon: false,
            ..
        }) => Some((*channel_id, *user_id)),
        _ => None,
    }
}
