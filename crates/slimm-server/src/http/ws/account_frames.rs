// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Frames private to one account: its read marker, its per-channel
//! notification overrides, its category mutes, a voice move or removal and a
//! connector's forwarded runs, delivered only to that account's own connections.

use super::authorization::Authorization;
use super::frames::ServerFrame;
use crate::hub::Event;
use crate::store::SessionContext;

/// `None` when `event` is not account-scoped. Decided before any channel
/// permission is consulted: the owner is the only audience, and everyone else
/// is withheld.
pub(super) fn authorize(ctx: &SessionContext, event: &Event) -> Option<Authorization> {
    let (owner, frame) = match event {
        Event::ReadStateChanged {
            user_id,
            channel_id,
            last_read_seq,
            manually_unread,
        } => (
            *user_id,
            ServerFrame::ReadStateChanged {
                channel_id: channel_id.to_string(),
                last_read_seq: *last_read_seq,
                manually_unread: *manually_unread,
            },
        ),
        Event::NotificationOverrideChanged {
            user_id,
            channel_id,
            preference,
        } => (
            *user_id,
            ServerFrame::NotificationOverrideChanged {
                channel_id: channel_id.to_string(),
                preference: preference.map(|p| p.as_str().to_owned()),
            },
        ),
        Event::CategoryMuteChanged {
            user_id,
            category_id,
            muted,
        } => (
            *user_id,
            ServerFrame::CategoryMuteChanged {
                category_id: category_id.to_string(),
                muted: *muted,
            },
        ),
        Event::VoiceMoved {
            user_id,
            from_channel_id,
            to_channel_id,
            to_channel_name,
            moved_by_id,
            moved_by_name,
        } => (
            *user_id,
            ServerFrame::VoiceMoved {
                from_channel_id: from_channel_id.to_string(),
                to_channel_id: to_channel_id.to_string(),
                to_channel_name: to_channel_name.clone(),
                moved_by_id: moved_by_id.to_string(),
                moved_by_name: moved_by_name.clone(),
            },
        ),
        Event::VoiceRemoved {
            user_id,
            channel_id,
            reason,
        } => (
            *user_id,
            ServerFrame::VoiceRemoved {
                channel_id: channel_id.to_string(),
                reason: reason.as_str(),
            },
        ),
        Event::VoiceNotice {
            user_id,
            channel_id,
            actor_id,
            activity,
        } => (
            *user_id,
            ServerFrame::VoiceNotice {
                channel_id: channel_id.to_string(),
                actor_id: actor_id.to_string(),
                activity: activity.as_str(),
            },
        ),
        Event::SoundboardPlayed {
            user_id,
            channel_id,
            clip_id,
            player_id,
        } => (
            *user_id,
            ServerFrame::SoundboardPlayed {
                channel_id: channel_id.to_string(),
                clip_id: clip_id.to_string(),
                player_id: player_id.to_string(),
            },
        ),
        Event::DmLeft {
            user_id,
            channel_id,
        } => (
            *user_id,
            ServerFrame::ChannelDeleted {
                channel_id: channel_id.to_string(),
            },
        ),
        Event::ConnectorRun(run) => (
            run.principal,
            ServerFrame::ConnectorRun {
                run_id: run.run_id.to_string(),
                module_id: run.module_id.clone(),
                deadline_ms: run.deadline_ms,
                request: run.request.clone(),
            },
        ),
        _ => return None,
    };
    Some(if owner == ctx.user_id {
        Authorization::Deliver(Box::new(frame))
    } else {
        Authorization::Withhold
    })
}
