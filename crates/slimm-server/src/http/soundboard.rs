// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The soundboard (decision 0118): the Space's named clips, and playing one into a call.
//!
//! Managed like custom emoji: readable by every member, written with
//! MANAGE_SERVER. Playing needs SPEAK and USE_SOUNDBOARD in the call's channel and a seat
//! in the call; the server only fans a signal out, and each client in the call
//! plays its own cached copy.

use std::collections::HashSet;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::Response;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::attachments::serve;
use super::error::ApiError;
use super::extract::{ASSET, AUTHED_READ, Authed, AuthedLimited, Bytes, Json, Query};
use super::extract::{enforce, require_manage_server};
use crate::hub::Event;
use crate::ids::{ChannelId, SoundClipId};
use crate::media;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::soundboard::{self, AddError};
use crate::store::SoundClip;
use crate::voice::VoiceError;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/soundboard", get(list).post(upload))
        .route_layer(DefaultBodyLimit::max(soundboard::MAX_CLIP_BYTES as usize))
        .route(
            "/soundboard/{clip_id}",
            axum::routing::patch(rename).delete(remove),
        )
        .route("/soundboard/{clip_id}/audio", get(audio))
        .route(
            "/channels/{channel_id}/voice/soundboard/{clip_id}/play",
            post(play),
        )
}

#[derive(Debug, Serialize)]
pub struct SoundClipDto {
    pub id: String,
    pub name: String,
    pub duration_ms: i64,
    pub uploader_id: Option<String>,
    pub created_at: i64,
}

impl From<SoundClip> for SoundClipDto {
    fn from(clip: SoundClip) -> Self {
        Self {
            id: clip.id,
            name: clip.name,
            duration_ms: clip.duration_ms,
            uploader_id: clip.uploader_id,
            created_at: clip.created_at,
        }
    }
}

#[derive(Debug, Deserialize)]
struct UploadParams {
    name: String,
}

#[derive(Debug, Deserialize)]
struct RenameRequest {
    name: String,
}

async fn list(
    AuthedLimited(_ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<SoundClipDto>>, ApiError> {
    let clips = state.store.list_sound_clips().await?;
    Ok(Json(clips.into_iter().map(SoundClipDto::from).collect()))
}

async fn upload(
    Authed(ctx): Authed,
    parts: Parts,
    Query(params): Query<UploadParams>,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<(StatusCode, Json<SoundClipDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;
    require_manage_server(&state, ctx.user_id).await?;
    super::storage_room::room_for(&state, body.len() as i64).await?;
    let clip = soundboard::add_clip(
        &state.store,
        &state.media,
        &params.name,
        body.to_vec(),
        ctx.user_id,
    )
    .await
    .map_err(refusal)?;
    Ok((StatusCode::CREATED, Json(clip.into())))
}

async fn rename(
    Authed(ctx): Authed,
    parts: Parts,
    Path(clip_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<RenameRequest>,
) -> Result<Json<SoundClipDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let id = parse_id(&clip_id)?;
    let name = soundboard::normalize_name(&req.name).ok_or(ApiError::BadRequest(NAME_RULE))?;
    match state.store.rename_sound_clip(id, &name).await? {
        None => Err(ApiError::NotFound("clip not found")),
        Some(Err(err)) => Err(refusal(soundboard::refused(err))),
        Some(Ok(clip)) => Ok(Json(clip.into())),
    }
}

/// Idempotent: removing a clip already gone is a 204.
async fn remove(
    Authed(ctx): Authed,
    parts: Parts,
    Path(clip_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    state.store.delete_sound_clip(parse_id(&clip_id)?).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn audio(
    AuthedLimited(_ctx): AuthedLimited<ASSET>,
    Path(clip_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let clip = state
        .store
        .sound_clip(parse_id(&clip_id)?)
        .await?
        .ok_or(ApiError::NotFound("clip not found"))?;
    let meta = state
        .store
        .attachment_summary(&media::from_hex(&clip.sha256).ok_or(ApiError::Internal)?)
        .await?
        .ok_or(ApiError::NotFound("clip not found"))?;
    let bytes = state
        .media
        .read_attachment(&clip.sha256)
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to read a stored soundboard clip");
            ApiError::Internal
        })?;
    Ok(serve(bytes, &meta.content_type, &meta.filename))
}

/// Tells everyone in the call, the caller included, to play a clip.
///
/// One private event per participant rather than a channel broadcast, so a
/// member who is only watching the channel never receives it.
async fn play(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, clip_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Soundboard)?;
    let channel_id = ChannelId(parse_id_uuid(&channel_id)?);
    let clip_id = parse_id(&clip_id)?;

    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    let needed = Permissions::VIEW_CHANNEL
        .union(Permissions::CONNECT)
        .union(Permissions::SPEAK)
        .union(Permissions::USE_SOUNDBOARD);
    if !permissions.contains(needed) {
        return Err(ApiError::Forbidden);
    }
    if state.store.sound_clip(clip_id).await?.is_none() {
        return Err(ApiError::NotFound("clip not found"));
    }

    let present = match state.voice.list_participants_shared(channel_id).await {
        Ok(list) => list,
        Err(VoiceError::Unavailable) => {
            return Err(ApiError::NotConfigured(
                "this server has no voice configured",
            ));
        }
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not list a call's participants for a soundboard play");
            return Err(ApiError::Unavailable);
        }
    };
    let audience: HashSet<_> = present.iter().map(|p| p.user_id).collect();
    if !audience.contains(&ctx.user_id) {
        return Err(ApiError::ForbiddenBecause("join the call to play a clip"));
    }
    for user_id in audience {
        state.hub.publish(Event::SoundboardPlayed {
            user_id,
            channel_id,
            clip_id,
            player_id: ctx.user_id,
        });
    }
    Ok(StatusCode::NO_CONTENT)
}

const NAME_RULE: &str = "clip name must be 1 to 32 characters";

fn refusal(err: AddError) -> ApiError {
    match err {
        AddError::UnusableName => ApiError::BadRequest(NAME_RULE),
        AddError::Empty => ApiError::BadRequest("clip is empty"),
        AddError::TooLarge => ApiError::BadRequest("clip must be at most 512 KB"),
        AddError::UnsupportedType => ApiError::BadRequest("clip must be an mp3 or wav file"),
        AddError::UnreadableLength => ApiError::BadRequest("could not read the clip's length"),
        AddError::TooLong => ApiError::BadRequest("clip must be at most 5 seconds"),
        AddError::NameTaken => ApiError::Conflict("a clip with that name already exists"),
        AddError::Full => ApiError::Conflict("this Space is at its soundboard limit"),
        AddError::Storage(err) => {
            tracing::error!(error = %err, "failed to store a soundboard clip");
            ApiError::Internal
        }
    }
}

fn parse_id_uuid(raw: &str) -> Result<uuid::Uuid, ApiError> {
    raw.parse().map_err(|_| ApiError::BadRequest("invalid id"))
}

fn parse_id(raw: &str) -> Result<SoundClipId, ApiError> {
    parse_id_uuid(raw).map(SoundClipId)
}
