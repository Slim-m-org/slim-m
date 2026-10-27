// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /members/bulk-removal` and `POST /members/bulk-timeout`: one
//! moderation act over several members.
//!
//! Split from `members.rs` rather than grown into it, the same reason
//! `messages_bulk` sits beside `messages`: that file is already carrying two
//! verbs, their undo halves, a listing and the shared guards.
//!
//! **Containment is enforced here, unlike the bulk message delete.** That is
//! not an inconsistency. `escalation_guard` has always guarded member
//! moderation - `members.rs::authorize` runs it on every single-target call -
//! so applying it per target here keeps the bulk verb exactly as strong as
//! doing the same thing one at a time. Decision 0016 removed the guard from
//! bulk message deletion for the opposite reason: the single message delete
//! never had one, so a guard there would have refused in bulk what already
//! succeeded slowly. The rule in both cases is that bulk matches single.
//!
//! Every target is checked before the first row moves. A batch that named one
//! member above the caller's level must not leave the ones before them in the
//! list already removed, which is `canvas_ops_apply`'s validate-all-then-write
//! rule and the reason the store side runs as a single transaction.

use std::collections::HashSet;

use futures_util::stream::{self, StreamExt};

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::post;
use serde::Deserialize;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::escalation::peer_guard;
use super::super::extract::{Authed, Json, enforce};
use super::super::messages::parse_uuid;
use super::super::safety::validate_reason;
use super::{evict_from_rooms, require, voice_room_ids};
use crate::hub::Event;
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{MAX_TIMEOUT_MS, RemoveMemberError, now_ms};

const BODY_LIMIT: usize = 4 * 1024;

/// Most members one bulk moderation request may name.
///
/// Sized against the fan-out rather than against politeness, the way
/// `MAX_BULK_DELETE_IDS` is. A removal publishes one `MemberRemoved` plus one
/// `SessionRevoked` per live session of that member, and the hub's
/// `CHANNEL_CAPACITY` is 1024 - past which a lagging subscriber is dropped and
/// has to resync. 64 targets leaves that headroom intact even for members
/// signed in on several devices.
///
/// It also bounds the voice eviction, which is the slow half: each target is
/// swept out of every voice channel and every DM they are party to.
pub const MAX_BULK_MEMBER_IDS: usize = 64;

/// How many members are swept out of voice at once; see [`evict_all_from_voice`].
const EVICT_CONCURRENCY: usize = 8;

#[derive(Deserialize)]
struct BulkRemovalRequest {
    user_ids: Vec<String>,
    reason: Option<String>,
}

#[derive(Deserialize)]
struct BulkTimeoutRequest {
    user_ids: Vec<String>,
    duration_seconds: i64,
    reason: Option<String>,
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/members/bulk-removal", post(bulk_remove))
        .route("/members/bulk-timeout", post(bulk_timeout))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// Removes several members at once. Requires BAN_MEMBERS, plus containment
/// against each target, matching `PUT /members/{id}/removal`.
async fn bulk_remove(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<BulkRemovalRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let targets = parse_targets(&req.user_ids, ctx.user_id)?;
    authorize_all(&state, ctx.user_id, &targets, Permissions::BAN_MEMBERS).await?;

    let reason = validate_reason(req.reason.as_deref(), false)?;
    let revoked = match state
        .store
        .bulk_remove_members(&targets, ctx.user_id, reason.as_deref())
        .await
    {
        Ok(revoked) => revoked,
        Err(RemoveMemberError::UserNotFound) => return Err(ApiError::NotFound("no such member")),
        Err(RemoveMemberError::LastAdministrator) => {
            return Err(ApiError::Conflict(
                "the last administrator cannot be removed",
            ));
        }
        Err(RemoveMemberError::Internal(err)) => return Err(err.into()),
    };

    for session_id in revoked {
        state.hub.publish(Event::SessionRevoked(session_id));
    }
    for target in &targets {
        state.hub.publish(Event::MemberRemoved(*target));
    }
    evict_all_from_voice(&state, &targets).await;
    Ok(StatusCode::NO_CONTENT)
}

/// Times several members out at once. Requires KICK_MEMBERS, plus containment
/// against each target, matching `PUT /members/{id}/timeout`.
async fn bulk_timeout(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<BulkTimeoutRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let targets = parse_targets(&req.user_ids, ctx.user_id)?;
    authorize_all(&state, ctx.user_id, &targets, Permissions::KICK_MEMBERS).await?;

    if req.duration_seconds <= 0 {
        return Err(ApiError::BadRequest("duration must be positive"));
    }
    let duration_ms = req
        .duration_seconds
        .checked_mul(1000)
        .filter(|ms| *ms <= MAX_TIMEOUT_MS)
        .ok_or(ApiError::BadRequest("duration is longer than 28 days"))?;
    // Once for the batch, so everyone in it comes back at the same moment.
    let until = now_ms() + duration_ms;

    let reason = validate_reason(req.reason.as_deref(), false)?;
    let changed = state
        .store
        .bulk_timeout_members(&targets, until, reason.as_deref(), ctx.user_id)
        .await?;

    for target in &changed {
        state.hub.publish(Event::MemberTimeoutChanged {
            user_id: *target,
            until: Some(until),
        });
    }
    evict_all_from_voice(&state, &changed).await;
    Ok(StatusCode::NO_CONTENT)
}

// --- Guards ---

/// The distinct targets named, refusing an empty list, an over-long one and
/// the caller themselves.
///
/// Duplicates collapse rather than being refused. A selection UI that offered
/// the same member twice is a client bug, not something the moderator should
/// have to untangle - but acting on them twice would write two audit rows for
/// one act, so the set is what reaches the store.
///
/// The cap is checked against the list as given rather than the deduplicated
/// set, so a caller cannot walk past it by repeating ids.
fn parse_targets(raw: &[String], caller: UserId) -> Result<Vec<UserId>, ApiError> {
    if raw.is_empty() {
        return Err(ApiError::BadRequest("no member ids given"));
    }
    if raw.len() > MAX_BULK_MEMBER_IDS {
        return Err(ApiError::BadRequest("too many member ids"));
    }

    let mut seen = HashSet::with_capacity(raw.len());
    let mut targets = Vec::with_capacity(raw.len());
    for id in raw {
        let target = UserId(parse_uuid(id)?);
        if target == caller {
            return Err(ApiError::BadRequest("you cannot moderate yourself"));
        }
        if seen.insert(target) {
            targets.push(target);
        }
    }
    Ok(targets)
}

/// The caller holds `needed`, and contains every one of `targets`.
///
/// Read as one pass before anything is written, so the refusal is the whole
/// request rather than a partly-applied one. `granted_base_permissions` is
/// what both sides compare, for the reason `members.rs` gives: reading
/// *granted* rather than effective permissions stops a timeout already in
/// force from being what makes somebody look junior enough to moderate again.
async fn authorize_all(
    state: &AppState,
    caller: UserId,
    targets: &[UserId],
    needed: Permissions,
) -> Result<(), ApiError> {
    require(state, caller, needed).await?;
    let caller_granted = state.store.granted_base_permissions(caller).await?;
    for target in targets {
        let target_granted = state.store.granted_base_permissions(*target).await?;
        peer_guard(caller_granted, target_granted)?;
    }
    Ok(())
}

/// Sweeps every target out of voice.
///
/// The shared voice room list is read once for the batch rather than once per
/// member, and the evictions run with bounded concurrency. Sequential would be
/// simpler, but each eviction is an SFU call carrying its own five-second
/// timeout, so sixty-four members across a handful of rooms could hold one
/// request open for the better part of an hour against a slow-but-answering
/// SFU. [`EVICT_CONCURRENCY`] bounds the wall clock without letting a batch
/// open an unbounded number of connections to the SFU at once.
///
/// Best effort throughout, as the single path is: the moderation act has
/// already committed, and this runs outside its transaction.
async fn evict_all_from_voice(state: &AppState, targets: &[UserId]) {
    let Some(rooms) = voice_room_ids(state).await else {
        return;
    };
    stream::iter(targets)
        .for_each_concurrent(EVICT_CONCURRENCY, |target| {
            let rooms = &rooms;
            async move { evict_from_rooms(state, *target, rooms).await }
        })
        .await;
}
