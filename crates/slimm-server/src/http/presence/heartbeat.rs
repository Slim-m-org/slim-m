// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Presence for a client with no socket: a heartbeat keeps the caller online until it lapses.
//!
//! It feeds the same tracker a socket does, so readers and the fan-out need no second path.

use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::AppState;
use crate::http::error::ApiError;
use crate::hub::Event;
use crate::ids::UserId;
use crate::presence::{BeatDue, HEARTBEAT_DEFAULT_TTL, HEARTBEAT_MAX_TTL, Visibility};
use crate::presence_activity::Activity;

#[derive(Deserialize)]
pub(super) struct HeartbeatRequest {
    status: Option<String>,
    activity: Option<Activity>,
    ttl_seconds: Option<u64>,
}

#[derive(Serialize)]
pub(super) struct HeartbeatDto {
    ttl_seconds: u64,
    expires_at: i64,
}

/// Records a heartbeat for `user_id`, applying any status and activity sent.
pub(super) fn record(
    state: &AppState,
    user_id: UserId,
    req: HeartbeatRequest,
) -> Result<HeartbeatDto, ApiError> {
    let ttl_seconds = req.ttl_seconds.unwrap_or(HEARTBEAT_DEFAULT_TTL.as_secs());
    if ttl_seconds == 0 || ttl_seconds > HEARTBEAT_MAX_TTL.as_secs() {
        return Err(ApiError::BadRequest(
            "ttl_seconds must be between 1 and 300",
        ));
    }
    let status = match req.status.as_deref() {
        None | Some("online") => Visibility::Online,
        Some("away") => Visibility::Away,
        Some("dnd") => Visibility::Dnd,
        Some(_) => {
            return Err(ApiError::BadRequest("status must be online, away, or dnd"));
        }
    };
    if let Some(activity) = &req.activity {
        activity
            .validate_from_client()
            .map_err(ApiError::BadRequest)?;
    }

    let recorded = state.hub.presence().beat(
        user_id,
        Duration::from_secs(ttl_seconds),
        status,
        req.activity,
        Instant::now(),
    );
    if recorded.changed {
        state.hub.publish(Event::presence_changed(user_id));
    }
    if let Some((generation, expires)) = recorded.timer {
        spawn_expiry(state.hub.clone(), user_id, generation, expires);
    }
    Ok(HeartbeatDto {
        ttl_seconds,
        expires_at: crate::store::now_ms() + i64::try_from(ttl_seconds * 1000).unwrap_or(0),
    })
}

/// Ends `user_id`'s heartbeat at once, announcing it when a viewer could tell.
pub(super) fn end(state: &AppState, user_id: UserId) {
    if state.hub.presence().end_beat(user_id) {
        state.hub.publish(Event::presence_changed(user_id));
    }
}

/// One timer per heartbeat, which sleeps to each refreshed expiry until the beat lapses.
fn spawn_expiry(hub: crate::hub::Hub, user_id: UserId, generation: u64, first: Instant) {
    tokio::spawn(async move {
        let mut due = first;
        loop {
            tokio::time::sleep_until(tokio::time::Instant::from_std(due)).await;
            match hub.presence().beat_due(user_id, generation, Instant::now()) {
                BeatDue::Later(next) => due = next,
                BeatDue::Ended { changed } => {
                    if changed {
                        hub.publish(Event::presence_changed(user_id));
                    }
                    return;
                }
                BeatDue::Gone => return,
            }
        }
    });
}
