// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Favorites: one person's ordered list of GIFs and media kept from messages.
//!
//! Private like `saved_messages`: no route takes a user id and no live event
//! is published. A favorite only ever stores a reference. Sending one goes
//! through [`select`], which re-checks that the sender can still see the
//! source message's channel, so a list is never a way to keep reading a
//! channel after losing it.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{HeaderValue, StatusCode, header, request::Parts};
use axum::response::Response;
use axum::routing::{get, post, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{ASSET, AUTHED_READ, Authed, AuthedLimited, GIF, Json, enforce};
use super::gifs::store_gif;
use super::messages::{AttachmentDto, parse_uuid};
use super::viewable_message::viewable_message;
use crate::ids::{FavoriteId, MessageId, UserId};
use crate::media;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{FavoriteError, FavoriteKind, FavoriteRow, MAX_FAVORITES, NewFavorite};

/// Bodies are tiny; the order list is the largest at 200 ids.
const BODY_LIMIT: usize = 64 * 1024;

const NO_SUCH_FAVORITE: &str = "no such favorite";
const UNAVAILABLE: &str = "that favorite is no longer available";

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/favorites", get(list).post(add))
        .route("/favorites/order", put(reorder))
        .route("/favorites/{favorite_id}", axum::routing::delete(remove))
        .route("/favorites/{favorite_id}/preview", get(preview))
        .route("/favorites/{favorite_id}/select", post(select))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct FavoriteDto {
    id: String,
    kind: &'static str,
    title: String,
    width: i64,
    height: i64,
    /// False when the source message is gone or its channel can no longer be viewed.
    available: bool,
    created_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    attachment_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content_type: Option<String>,
    /// Present only while the entry is available.
    #[serde(skip_serializing_if = "Option::is_none")]
    message_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    channel_id: Option<String>,
}

fn to_dto(row: FavoriteRow, can_view: bool) -> FavoriteDto {
    let gif = row.kind == FavoriteKind::Gif;
    let available = gif || (can_view && row.channel_id.is_some());
    FavoriteDto {
        id: row.id.to_string(),
        kind: if gif { "gif" } else { "attachment" },
        title: row.title,
        width: row.width,
        height: row.height,
        available,
        created_at: row.created_at,
        attachment_id: row.attachment_sha256.as_deref().map(media::to_hex),
        content_type: row.content_type,
        message_id: row.message_id.filter(|_| available).map(|m| m.to_string()),
        channel_id: row.channel_id.filter(|_| available).map(|c| c.to_string()),
    }
}

/// Whether the caller can view the source channel of each row, in one batch.
async fn viewable(
    state: &AppState,
    user_id: UserId,
    rows: &[FavoriteRow],
) -> Result<Vec<bool>, ApiError> {
    let channels: Vec<_> = rows
        .iter()
        .filter_map(|r| r.channel_id)
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect();
    let permissions = state
        .store
        .permissions_in_channels(user_id, &channels)
        .await?;
    Ok(rows
        .iter()
        .map(|r| {
            r.channel_id.is_some_and(|c| {
                permissions
                    .get(&c)
                    .is_some_and(|p| p.contains(Permissions::VIEW_CHANNEL))
            })
        })
        .collect())
}

async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<FavoriteDto>>, ApiError> {
    let rows = state.store.list_favorites(ctx.user_id).await?;
    let can_view = viewable(&state, ctx.user_id, &rows).await?;
    Ok(Json(
        rows.into_iter()
            .zip(can_view)
            .map(|(r, v)| to_dto(r, v))
            .collect(),
    ))
}

#[derive(Deserialize)]
struct AddRequest {
    id: String,
    kind: String,
    /// A live search or trending result id, for `kind: gif`.
    #[serde(default)]
    gif_id: Option<String>,
    #[serde(default)]
    message_id: Option<String>,
    #[serde(default)]
    attachment_id: Option<String>,
}

/// Adds a favorite at the front of the list, idempotently.
async fn add(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<AddRequest>,
) -> Result<(StatusCode, Json<FavoriteDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let id = FavoriteId(parse_uuid(&req.id)?);
    let new = match req.kind.as_str() {
        "gif" => new_gif(&state, &req)?,
        "attachment" => new_attachment(&state, ctx.user_id, &req).await?,
        _ => return Err(ApiError::BadRequest("kind must be gif or attachment")),
    };
    match state.store.add_favorite(ctx.user_id, id, &new).await {
        Ok(row) => {
            let can_view = viewable(&state, ctx.user_id, std::slice::from_ref(&row)).await?;
            Ok((StatusCode::CREATED, Json(to_dto(row, can_view[0]))))
        }
        Err(FavoriteError::TooMany) => Err(ApiError::BadRequest(
            "you already have as many favorites as an account can hold",
        )),
        Err(FavoriteError::Taken) => Err(ApiError::Conflict("that favorite id is already in use")),
        Err(FavoriteError::Internal(e)) => Err(e.into()),
    }
}

fn new_gif(state: &AppState, req: &AddRequest) -> Result<NewFavorite, ApiError> {
    let token = req
        .gif_id
        .as_deref()
        .ok_or(ApiError::BadRequest("gif_id is required for a gif"))?;
    let snap = state.gifs.snapshot(token)?;
    Ok(NewFavorite::Gif {
        title: snap.title,
        width: snap.width,
        height: snap.height,
        preview_url: snap.preview_url,
        full_url: snap.full_url,
    })
}

async fn new_attachment(
    state: &AppState,
    user_id: UserId,
    req: &AddRequest,
) -> Result<NewFavorite, ApiError> {
    let (Some(message), Some(attachment)) = (&req.message_id, &req.attachment_id) else {
        return Err(ApiError::BadRequest(
            "message_id and attachment_id are required for an attachment",
        ));
    };
    let message_id = MessageId(parse_uuid(message)?);
    let sha256 = media::from_hex(attachment)
        .filter(|b| b.len() == 32)
        .ok_or(ApiError::BadRequest("invalid attachment id"))?;
    viewable_message(state, user_id, message_id).await?;
    let (content_type, filename) = state
        .store
        .live_message_attachment(message_id, &sha256)
        .await?
        .ok_or(ApiError::NotFound("no such attachment on that message"))?;
    if !(content_type.starts_with("image/") || content_type.starts_with("video/")) {
        return Err(ApiError::BadRequest(
            "only images and videos can be favorites",
        ));
    }
    Ok(NewFavorite::Attachment {
        sha256,
        message_id,
        content_type,
        filename,
    })
}

/// Removes an entry. Asks for no permission: letting go is never refused.
async fn remove(
    Authed(ctx): Authed,
    parts: Parts,
    Path(favorite_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let id = FavoriteId(parse_uuid(&favorite_id)?);
    state.store.remove_favorite(ctx.user_id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct OrderRequest {
    ids: Vec<String>,
}

/// Puts the named entries first, in order; unnamed entries keep their place after them.
async fn reorder(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<OrderRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if req.ids.len() as i64 > MAX_FAVORITES {
        return Err(ApiError::BadRequest("too many ids"));
    }
    let ids = req
        .ids
        .iter()
        .map(|raw| parse_uuid(raw).map(FavoriteId))
        .collect::<Result<Vec<_>, _>>()?;
    state.store.reorder_favorites(ctx.user_id, &ids).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// The caller's own entry, or the same 404 an absent one gets.
async fn owned(state: &AppState, user_id: UserId, raw: &str) -> Result<FavoriteRow, ApiError> {
    let id = FavoriteId(parse_uuid(raw)?);
    state
        .store
        .favorite(user_id, id)
        .await?
        .ok_or(ApiError::NotFound(NO_SUCH_FAVORITE))
}

/// A GIF favorite's thumbnail, streamed through this server like a search preview.
async fn preview(
    AuthedLimited(ctx): AuthedLimited<ASSET>,
    Path(favorite_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let row = owned(&state, ctx.user_id, &favorite_id).await?;
    let url = row
        .gif_preview_url
        .ok_or(ApiError::NotFound("only a gif has a preview here"))?;
    let bytes = state.gifs.preview_bytes_from(&url).await?;
    let content_type = media::sniff_content_type(&bytes).ok_or(ApiError::Unavailable)?;
    let mut response = Response::new(axum::body::Body::from(bytes));
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, max-age=600"),
    );
    Ok(response)
}

#[derive(Deserialize)]
struct SelectRequest {
    #[serde(default)]
    channel_id: Option<String>,
}

/// Turns a favorite into an attachment the composer can stage, as `selectGif` does.
///
/// An attachment favorite re-checks the source message's channel now; losing
/// the message or the channel answers 409 rather than serving the file.
async fn select(
    AuthedLimited(ctx): AuthedLimited<GIF>,
    Path(favorite_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<SelectRequest>,
) -> Result<(StatusCode, Json<AttachmentDto>), ApiError> {
    super::attachment_uploads::may_attach(&state, ctx.user_id, req.channel_id.as_deref()).await?;
    let row = owned(&state, ctx.user_id, &favorite_id).await?;
    match row.kind {
        FavoriteKind::Gif => {
            let url = row.gif_full_url.ok_or(ApiError::Internal)?;
            let bytes = state.gifs.download_full_from(&url).await?;
            let attachment = store_gif(&state, ctx.user_id, bytes, &row.title).await?;
            Ok((StatusCode::CREATED, Json(attachment)))
        }
        FavoriteKind::Attachment => {
            let (Some(message_id), Some(sha256)) = (row.message_id, row.attachment_sha256) else {
                return Err(ApiError::Conflict(UNAVAILABLE));
            };
            viewable_message(&state, ctx.user_id, message_id)
                .await
                .map_err(|_| ApiError::Conflict(UNAVAILABLE))?;
            let summary = state
                .store
                .attachment_summary(&sha256)
                .await?
                .ok_or(ApiError::Conflict(UNAVAILABLE))?;
            Ok((StatusCode::OK, Json(AttachmentDto::from(summary))))
        }
    }
}
