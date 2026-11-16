// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Stamps on a shared screen (decision 0121): an emoji or a picture a viewer places on
//! someone's share, relayed like any other screen mark, and the sharer's list of pictures.
//!
//! A REST route rather than a socket frame, like a soundboard play: it needs the call
//! roster, the attachment rules and a refusal the sender can see.

use std::sync::Arc;
use std::time::Instant;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::Serialize;

use super::AppState;
use super::canvas::canvas_write::ensure_may_draw;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::{
    CanvasEvent, Event, ScreenAnnotationEvent, ScreenAnnotationKind, Stamp, StampContent,
};
use crate::ids::{ChannelId, UserId};
use crate::media::{self, ImageHeader};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{NewScreenStamp, SCREEN_STAMP_TTL_MS, ScreenStamp, StampInsert, now_ms};
use crate::voice::VoiceError;
use stamp_checks::{Checked, Content, StampRequest, check, custom_emoji_id};

pub(in crate::http) mod stamp_access;
mod stamp_checks;

const BODY_LIMIT: usize = 2 * 1024;

/// The largest picture a stamp may show.
const MAX_STAMP_PICTURE_BYTES: i64 = 8 * 1024 * 1024;

/// The largest GIF an in-app tile animates; a bigger one shows its still frame.
const MAX_ANIMATED_BYTES: i64 = 4 * 1024 * 1024;

/// The longest GIF canvas side a tile animates, since every frame decodes at the full canvas.
const MAX_ANIMATED_SIDE: u32 = 1024;

const NOT_A_PICTURE: &str = "a stamp must be a PNG, JPEG, GIF or WebP picture";

/// The picture types a stamp may show, as upload sniffing names them.
const STAMP_PICTURE_TYPES: [&str; 4] = ["image/png", "image/jpeg", "image/gif", "image/webp"];

/// Most pictures the sharer's list returns.
const RECEIVED_LIMIT: i64 = 100;

const NOT_TAKING: &str = "Their screen is not taking stamps right now";

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/voice/screen-stamps", post(place))
        .route("/voice/screen-stamps/received", get(received))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// Places a stamp on `target_user_id`'s shared screen, in the order decision 0121 lists.
///
/// Idempotent by id for a picture. A target who blocked the sender gets nothing, and the
/// sender still gets 204, so a block cannot be told from a delivery.
async fn place(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<StampRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::ScreenStamp)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let stamp = check(req).map_err(ApiError::BadRequest)?;
    if let Content::Emoji(key) = &stamp.content
        && let Some(emoji_id) = custom_emoji_id(key)
        && state.store.custom_emoji_sha256(emoji_id).await?.is_none()
    {
        return Err(ApiError::BadRequest("that custom emoji does not exist"));
    }
    let permissions = ensure_may_draw(&state, ctx.user_id, channel_id).await?;
    let picture = matches!(stamp.content, Content::Picture(_));
    if picture && !permissions.contains(Permissions::ATTACH_FILES) {
        return Err(ApiError::Forbidden);
    }
    if stamp.target == ctx.user_id {
        return Err(ApiError::BadRequest("you cannot stamp your own screen"));
    }
    let content = match &stamp.content {
        Content::Emoji(key) => StampContent::Emoji(key.clone()),
        Content::Picture(sha256) => StampContent::Picture {
            attachment: media::to_hex(sha256),
            animated: usable_picture(&state, ctx.user_id, sha256).await?,
        },
    };
    require_sharing_call(&state, channel_id, ctx.user_id, stamp.target).await?;
    let now = Instant::now();
    if !state
        .hub
        .screen_consent()
        .live_for_stamps(channel_id, stamp.target, now)
    {
        return Err(ApiError::Conflict(NOT_TAKING));
    }
    if state.store.has_blocked(stamp.target, ctx.user_id).await? {
        return Ok(StatusCode::NO_CONTENT);
    }
    if !record(&state, channel_id, ctx.user_id, &stamp).await? {
        return Ok(StatusCode::NO_CONTENT);
    }
    state
        .hub
        .publish(Event::Canvas(CanvasEvent::ScreenAnnotation(Arc::new(
            relayed(channel_id, ctx.user_id, &stamp, content),
        ))));
    Ok(StatusCode::NO_CONTENT)
}

/// Whether a picture may go on a screen, and whether a tile should animate it.
///
/// The sender must be able to use the attachment by the rule a message uses; anyone else
/// gets the fetch route's 404.
async fn usable_picture(state: &AppState, sender: UserId, sha256: &[u8]) -> Result<bool, ApiError> {
    let missing = ApiError::NotFound("attachment not found");
    if !state.store.can_fetch_attachment(sender, sha256).await? {
        return Err(missing);
    }
    let meta = state
        .store
        .attachment_summary(sha256)
        .await?
        .ok_or(missing)?;
    if !STAMP_PICTURE_TYPES.contains(&meta.content_type.as_str()) {
        return Err(ApiError::BadRequest(NOT_A_PICTURE));
    }
    if meta.size > MAX_STAMP_PICTURE_BYTES {
        return Err(ApiError::BadRequest(
            "a stamp picture must be at most 8 MiB",
        ));
    }
    let header = stillable_header(state, sha256).await?;
    Ok(meta.content_type == "image/gif"
        && meta.size <= MAX_ANIMATED_BYTES
        && header.width.max(header.height) <= MAX_ANIMATED_SIDE)
}

/// The picture's header, read the way its still is planned, so every stamp has a still the
/// server derives rather than an original of any pixel size.
async fn stillable_header(state: &AppState, sha256: &[u8]) -> Result<ImageHeader, ApiError> {
    let original = state.media.attachment_file(&media::to_hex(sha256));
    let header = state
        .media
        .previews()
        .header_for(&original)
        .await
        .filter(|header| header.width > 0 && header.height > 0)
        .ok_or(ApiError::BadRequest(NOT_A_PICTURE))?;
    if u64::from(header.width) * u64::from(header.height) > media::MAX_IMAGE_PIXELS {
        return Err(ApiError::BadRequest(
            "a stamp picture must be at most 40 megapixels",
        ));
    }
    Ok(header)
}

/// Both people in this channel's call, and the target sharing a screen there.
async fn require_sharing_call(
    state: &AppState,
    channel_id: ChannelId,
    sender: UserId,
    target: UserId,
) -> Result<(), ApiError> {
    let present = match state.voice.list_participants_shared(channel_id).await {
        Ok(list) => list,
        Err(VoiceError::Unavailable) => {
            return Err(ApiError::NotConfigured(
                "this server has no voice configured",
            ));
        }
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not list a call's participants for a screen stamp");
            return Err(ApiError::Unavailable);
        }
    };
    if !present.iter().any(|p| p.user_id == sender) {
        return Err(ApiError::ForbiddenBecause("Join the call to stamp"));
    }
    if !present
        .iter()
        .any(|p| p.user_id == target && p.is_sharing_screen)
    {
        return Err(ApiError::Conflict(NOT_TAKING));
    }
    Ok(())
}

/// Stores a picture stamp; false when this id already stored the same one, so nothing relays.
///
/// An emoji stamp stores nothing, but may not reuse a picture stamp's id.
async fn record(
    state: &AppState,
    channel_id: ChannelId,
    sender: UserId,
    stamp: &Checked,
) -> Result<bool, ApiError> {
    let reused = ApiError::Conflict("that stamp id is already used");
    let Content::Picture(sha256) = &stamp.content else {
        return match state.store.screen_stamp(stamp.id).await? {
            Some(_) => Err(reused),
            None => Ok(true),
        };
    };
    let new = NewScreenStamp {
        id: stamp.id,
        channel_id,
        sender_id: sender,
        target_id: stamp.target,
        sha256,
    };
    match state.store.insert_screen_stamp(&new).await? {
        StampInsert::Fresh => Ok(true),
        StampInsert::Replay => Ok(false),
        StampInsert::Conflict => Err(reused),
        StampInsert::Gone => Err(ApiError::NotFound("attachment not found")),
    }
}

fn relayed(
    channel_id: ChannelId,
    sender: UserId,
    stamp: &Checked,
    content: StampContent,
) -> ScreenAnnotationEvent {
    ScreenAnnotationEvent {
        channel_id,
        user_id: sender,
        target_user_id: stamp.target,
        kind: ScreenAnnotationKind::Stamp,
        annotation_id: Some(stamp.id),
        points: vec![stamp.centre.0, stamp.centre.1],
        color: None,
        text: None,
        ended: true,
        allowed: false,
        aspect: None,
        stamp: Some(Stamp {
            size: stamp.size,
            content,
        }),
        stamps: false,
    }
}

#[derive(Serialize)]
struct ReceivedStampDto {
    id: String,
    channel_id: String,
    sender_id: String,
    attachment_id: String,
    created_at: i64,
    reported: bool,
}

impl From<ScreenStamp> for ReceivedStampDto {
    fn from(stamp: ScreenStamp) -> Self {
        Self {
            id: stamp.id.to_string(),
            channel_id: stamp.channel_id.to_string(),
            sender_id: stamp.sender_id.to_string(),
            attachment_id: media::to_hex(&stamp.sha256),
            created_at: stamp.created_at,
            reported: stamp.report_id.is_some(),
        }
    }
}

#[derive(Serialize)]
struct ReceivedStamps {
    stamps: Vec<ReceivedStampDto>,
}

/// The pictures stamped on the caller's screen in the last day, newest first.
async fn received(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<ReceivedStamps>, ApiError> {
    let since = now_ms() - SCREEN_STAMP_TTL_MS;
    let stamps = state
        .store
        .screen_stamps_received(ctx.user_id, since, RECEIVED_LIMIT)
        .await?;
    Ok(Json(ReceivedStamps {
        stamps: stamps.into_iter().map(ReceivedStampDto::from).collect(),
    }))
}
