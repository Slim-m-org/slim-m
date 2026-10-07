// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Devices, blocking, and reporting.
//!
//! These exist partly because the app stores require them (an account must be
//! able to see its sessions, block someone, and report content), and partly
//! because they are the safety model the owner chose: human review of manual
//! reports, no automated scanning of anything.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{delete, get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::ephemeral_report;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, WRITE, enforce};
use super::messages::parse_uuid;
use super::viewable_message::viewable_message;
use crate::hub::Event;
use crate::ids::{DeviceId, MessageId, UserId};
use crate::ratelimit::Class;
use crate::store::{Device, EPHEMERAL_KIND, FiledReport, ReportError, ReportSubject};
use crate::voice::VoiceError;

const BODY_LIMIT: usize = 32 * 1024;
const MAX_REASON_CHARS: usize = 2000;

/// Trims a caller-supplied reason and bounds its length.
///
/// Shared with the moderation verbs in [`super::members`], which had no cap at
/// all: only the module's 4 KiB body limit stood between a timeout or a removal
/// reason and `GET /members/removed` handing it back verbatim for every removal
/// in force. Neither route is reachable without KICK_MEMBERS or BAN_MEMBERS, so
/// there is no attacker here; what there is, is a length contract a client
/// rendering that list can design against, and consistency with every other
/// free-text field in this API - message 4000, poll question 300, topic 256,
/// search 200, display name 64, push token 1024, all capped explicitly.
///
/// `required` is what differs: a report must say why, a timeout need not.
pub(super) fn validate_reason(
    reason: Option<&str>,
    required: bool,
) -> Result<Option<String>, ApiError> {
    let trimmed = reason.map(str::trim).filter(|value| !value.is_empty());
    match trimmed {
        None if required => Err(ApiError::BadRequest("a reason is required")),
        None => Ok(None),
        Some(value) if value.chars().count() > MAX_REASON_CHARS => {
            Err(ApiError::BadRequest("that reason is too long"))
        }
        Some(value) if value.chars().any(is_hidden_reason_char) => Err(ApiError::BadRequest(
            "reason must not contain control or invisible characters",
        )),
        Some(value) => Ok(Some(value.to_owned())),
    }
}

/// A reason may run to several lines, so line breaks and tabs are ordinary text here.
fn is_hidden_reason_char(c: char) -> bool {
    !matches!(c, '\t' | '\n' | '\r') && super::hidden_chars::is_hidden_char(c)
}

/// The device, block, and report routes.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/devices", get(list_devices))
        .route("/devices/{device_id}", delete(remove_device))
        .route("/blocks", get(list_blocks))
        .route("/blocks/{user_id}", post(block).delete(unblock))
        .route("/reports", post(file_report))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

// --- Wire types ---

#[derive(Serialize)]
struct DeviceDto {
    id: String,
    name: String,
    created_at: i64,
    last_seen_at: Option<i64>,
    /// A coarse client kind ("ios", "android", "desktop", "web"), or `null`
    /// for a session opened before this field existed.
    client_kind: Option<String>,
    /// The app version that opened this session, or `null`; same absence
    /// rule as `client_kind`.
    client_version: Option<String>,
    is_current: bool,
}

impl From<Device> for DeviceDto {
    fn from(device: Device) -> Self {
        Self {
            id: device.id.to_string(),
            name: device.name,
            created_at: device.created_at,
            last_seen_at: device.last_seen_at,
            client_kind: device.client_kind,
            client_version: device.client_version,
            is_current: device.is_current,
        }
    }
}

#[derive(Deserialize)]
struct ReportRequest {
    /// A client-minted UUIDv7 that makes the filing idempotent, like every
    /// other durable write. Optional for older clients, which get a
    /// server-minted id and the pre-existing 409-on-retry behaviour.
    #[serde(default)]
    id: Option<String>,
    /// "message" or "user".
    subject_kind: String,
    subject_id: String,
    reason: String,
    /// Only for "ephemeral_message": the channel, the bot and the text the
    /// reporter was shown, since the server kept none of it.
    #[serde(default)]
    channel_id: Option<String>,
    #[serde(default)]
    author_id: Option<String>,
    #[serde(default)]
    snapshot: Option<String>,
}

#[derive(Serialize)]
struct ReportFiled {
    id: String,
}

// --- Devices ---

async fn list_devices(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<DeviceDto>>, ApiError> {
    let devices = state.store.list_devices(ctx.user_id, ctx.device_id).await?;
    Ok(Json(devices.into_iter().map(DeviceDto::from).collect()))
}

/// Signs a device out. Only ever your own: a device on someone else's account
/// is reported as missing, so this cannot be used to probe for or evict others.
async fn remove_device(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(device_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    let device_id = DeviceId(parse_uuid(&device_id)?);
    let revoked = state
        .store
        .remove_device(ctx.user_id, device_id)
        .await?
        .ok_or(ApiError::NotFound("device not found"))?;

    // Close any live socket on those sessions at once, the same as logout.
    for session_id in revoked {
        state.hub.publish(Event::SessionRevoked(session_id));
    }
    Ok(StatusCode::NO_CONTENT)
}

// --- Blocking ---

async fn list_blocks(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<String>>, ApiError> {
    let blocked = state.store.blocked_users(ctx.user_id).await?;
    Ok(Json(blocked.into_iter().map(|id| id.to_string()).collect()))
}

/// Blocks someone. Idempotent, and silent by design: the blocked user is never
/// notified, because telling them turns blocking into a provocation.
///
/// Also ends the blocked party's presence on the one call blocking can reach:
/// the DM shared with the blocker, if the pair ever opened one and a call is
/// live on it right now. `store/dms.rs`'s `BLOCKED_DENY` already stops a new
/// one being started or joined in either direction; without this, a call
/// already under way when the block landed kept running until somebody chose
/// to hang up, which is the same "a bearer credential cannot be revoked"
/// reason `members::evict_from_voice` exists at all.
async fn block(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    if target == ctx.user_id {
        return Err(ApiError::BadRequest("you cannot block yourself"));
    }
    // Checked before the insert: user_blocks has a foreign key on the target,
    // which INSERT OR IGNORE does not cover, so a never-existed id was a 500.
    if !state.store.user_row_exists(target).await? {
        return Err(ApiError::NotFound("that user was not found"));
    }
    state.store.block_user(ctx.user_id, target).await?;
    evict_blocked_from_shared_call(&state, ctx.user_id, target).await;
    Ok(StatusCode::NO_CONTENT)
}

/// [`block`]'s eviction half, best effort like [`super::members`]'s own: the
/// block has already committed by the time this runs, so a failure here has
/// nothing useful for a retry to do differently.
///
/// Only `blocked` is evicted, never `blocker`: the blocker already holds
/// their own remedy for an ongoing call (hang up), and a block is one
/// person's choice about future contact, not grounds to end a call the other
/// side may still want to be on.
async fn evict_blocked_from_shared_call(state: &AppState, blocker: UserId, blocked: UserId) {
    let Ok(Some(channel_id)) = state.store.dm_channel_for_pair(blocker, blocked).await else {
        return;
    };
    match state.voice.remove_participant(channel_id, blocked).await {
        Ok(()) | Err(VoiceError::Unavailable) => {}
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not evict a blocked party from a shared call");
        }
    }
}

async fn unblock(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    state.store.unblock_user(ctx.user_id, target).await?;
    Ok(StatusCode::NO_CONTENT)
}

// --- Reports ---

/// Files a report for a human to review. Nothing here inspects content
/// automatically; the whole point is that a person decides.
async fn file_report(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<ReportRequest>,
) -> Result<Json<ReportFiled>, ApiError> {
    // Charged like any other write: intake was unthrottled while triage was
    // rate-limited, so one account could fill the queue with a fresh random
    // subject id per request faster than a moderator was allowed to clear it.
    enforce(&state, &parts, Some(&ctx), Class::Write)?;

    let reason = validate_reason(Some(&req.reason), true)?
        .expect("a required reason is Some or the call above returned");
    let report_id = req.id.as_deref().map(parse_uuid).transpose()?;

    if req.subject_kind == EPHEMERAL_KIND {
        return file_ephemeral_report(&state, ctx.user_id, report_id, &req, &reason).await;
    }
    if req.channel_id.is_some() || req.author_id.is_some() || req.snapshot.is_some() {
        return Err(ApiError::BadRequest(
            "channel_id, author_id and snapshot are only for ephemeral_message",
        ));
    }
    let id = parse_uuid(&req.subject_id)?;
    let subject = match req.subject_kind.as_str() {
        "message" => ReportSubject::Message(MessageId(id)),
        "user" => ReportSubject::User(UserId(id)),
        _ => {
            return Err(ApiError::BadRequest(
                "subject_kind must be message, user or ephemeral_message",
            ));
        }
    };

    match subject {
        // Reporting a message requires being able to see it, so the endpoint
        // cannot confirm a message exists in a channel you cannot read.
        ReportSubject::Message(message_id) => {
            let (message, _) = viewable_message(&state, ctx.user_id, message_id).await?;
            if message.author_id == Some(ctx.user_id) {
                return Err(ApiError::BadRequest("you cannot report your own message"));
            }
        }
        // A user subject has no foreign key on the report row, so a random id
        // would otherwise be accepted and sit in the queue naming nobody.
        ReportSubject::User(user_id) => {
            if user_id == ctx.user_id {
                return Err(ApiError::BadRequest("you cannot report yourself"));
            }
            if !state.store.user_row_exists(user_id).await? {
                return Err(ApiError::NotFound("that user was not found"));
            }
        }
    }

    let filed = state
        .store
        .file_report_with_id(
            report_id.unwrap_or_else(uuid::Uuid::now_v7),
            ctx.user_id,
            subject,
            &reason,
        )
        .await;
    filed_response(&state, filed)
}

async fn file_ephemeral_report(
    state: &AppState,
    reporter: UserId,
    report_id: Option<uuid::Uuid>,
    req: &ReportRequest,
    reason: &str,
) -> Result<Json<ReportFiled>, ApiError> {
    let claim = ephemeral_report::parse(&ephemeral_report::Claim {
        message_id: &req.subject_id,
        channel_id: req.channel_id.as_deref(),
        author_id: req.author_id.as_deref(),
        snapshot: req.snapshot.as_deref(),
    })?;
    ephemeral_report::authorize(state, reporter, &claim).await?;
    let filed = state
        .store
        .file_ephemeral_report(
            report_id.unwrap_or_else(uuid::Uuid::now_v7),
            reporter,
            &claim.subject(),
            reason,
        )
        .await;
    filed_response(state, filed)
}

fn filed_response(
    state: &AppState,
    filed: Result<FiledReport, ReportError>,
) -> Result<Json<ReportFiled>, ApiError> {
    match filed {
        Ok(filed) => {
            // A replay changed nothing, so nothing is announced; see `Event::ReportsChanged`'s own doc.
            if filed.fresh {
                state.hub.publish(Event::ReportsChanged);
            }
            Ok(Json(ReportFiled {
                id: filed.id.to_string(),
            }))
        }
        Err(ReportError::AlreadyOpen) => Err(ApiError::Conflict("you already reported that")),
        Err(ReportError::IdConflict) => Err(ApiError::Conflict(
            "that report id already names a different report",
        )),
        Err(ReportError::NotFound) => Err(ApiError::NotFound("that was not found")),
        Err(ReportError::Internal(e)) => Err(e.into()),
    }
}
