// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Custom emoji: the deployment's own named images.
//!
//! Access is deliberately not the attachment rule. An attachment is readable
//! by whoever may view a channel referencing it; an emoji is readable by every
//! authenticated member, because it renders inside any message they may
//! already read, and gating it per channel would leak which channels use which
//! emoji. Writing is gated on MANAGE_SERVER, the bit that already means
//! "change what this deployment is".
//!
//! The bytes go through `media` and the `attachments` row exactly as a message
//! attachment does, so the storage, the sniffing and the dedup are one
//! implementation rather than two.
//!
//! Naming and creation live in [`crate::emoji`], shared with the bulk import,
//! so this module only turns one caller's request into that call and its
//! result into a status code.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::Response;
use axum::routing::{delete, get, post};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::attachments::serve;
use super::error::ApiError;
use super::extract::Authed;
use super::extract::enforce;
use super::extract::require_manage_server;
use super::extract::{ASSET, AUTHED_READ, AuthedLimited, Bytes, Json, Query};
use crate::emoji::bulk::{self, BulkAddError};
use crate::emoji::{self, AddError};
use crate::ids::EmojiId;
use crate::media;
use crate::ratelimit::Class;

/// The JSON body of a [`bulk_upload`] request base64-encodes every image, so
/// the wire body inflates by roughly a third over the decoded bytes
/// [`bulk::MAX_BULK_TOTAL_BYTES`] bounds; this leaves headroom for that plus
/// the surrounding JSON structure without letting the route buffer something
/// unbounded.
const BULK_BODY_LIMIT_BYTES: usize = (bulk::MAX_BULK_TOTAL_BYTES as usize / 3) * 4 + 65_536;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/emoji", get(list).post(upload))
        .route_layer(DefaultBodyLimit::max(emoji::MAX_IMAGE_BYTES as usize))
        .route("/emoji/{emoji_id}", delete(remove))
        .route("/emoji/{emoji_id}/image", get(image))
        .route("/emoji/bulk", post(bulk_upload))
        .route_layer(DefaultBodyLimit::max(BULK_BODY_LIMIT_BYTES))
}

// --- Wire types ---

#[derive(Debug, Serialize)]
pub struct CustomEmojiDto {
    pub id: String,
    pub name: String,
    pub uploader_id: Option<String>,
    pub created_at: i64,
    /// Upload response only: the name of an older emoji with exactly these
    /// bytes, so a client can offer to keep that one instead.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub same_image_as: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UploadParams {
    pub name: String,
}

#[derive(Debug, Deserialize)]
struct BulkUploadImage {
    name: String,
    /// Standard base64 of the image's raw bytes.
    data: String,
}

#[derive(Debug, Deserialize)]
struct BulkUploadRequest {
    images: Vec<BulkUploadImage>,
}

// --- Handlers ---

/// Every emoji in the deployment, for any authenticated caller.
async fn list(
    AuthedLimited(_ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<CustomEmojiDto>>, ApiError> {
    let emoji = state.store.list_custom_emoji().await?;
    Ok(Json(
        emoji
            .into_iter()
            .map(|e| CustomEmojiDto {
                id: e.id,
                name: e.name,
                uploader_id: e.uploader_id,
                created_at: e.created_at,
                same_image_as: None,
            })
            .collect(),
    ))
}

/// Adds an emoji. The name is normalised to what a member can actually type
/// between colons, so `:Big Smile:` and `:big_smile:` cannot both exist and
/// then disagree about which one a message meant.
async fn upload(
    Authed(ctx): Authed,
    parts: Parts,
    Query(params): Query<UploadParams>,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<(StatusCode, Json<CustomEmojiDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;
    require_manage_server(&state, ctx.user_id).await?;

    super::attachments::room_for(&state, body.len() as i64).await?;
    let created = emoji::add_emoji(
        &state.store,
        &state.media,
        &params.name,
        body.to_vec(),
        Some(ctx.user_id),
    )
    .await
    .map_err(refusal)?;
    let same_image_as = state
        .store
        .list_custom_emoji()
        .await?
        .into_iter()
        .find(|e| e.sha256 == created.sha256 && e.id != created.id)
        .map(|e| e.name);

    Ok((
        StatusCode::CREATED,
        Json(CustomEmojiDto {
            id: created.id,
            name: created.name,
            uploader_id: created.uploader_id,
            created_at: created.created_at,
            same_image_as,
        }),
    ))
}

/// Adds several emoji from one request, charged once against `Class::Upload`
/// however many images it carries - see [`bulk`]'s own module doc for why a
/// per-image charge made a large pack unimportable.
///
/// Validated and written as a whole: an unusable image or a name collision
/// anywhere in the batch refuses the entire request, so a caller can reason
/// about it as one act rather than a sequence that might stop partway. A
/// batch too large for one call, or too large to accept in this deployment's
/// remaining storage, refuses the same way - never truncated to what would
/// have fit.
async fn bulk_upload(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<BulkUploadRequest>,
) -> Result<(StatusCode, Json<Vec<CustomEmojiDto>>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;
    require_manage_server(&state, ctx.user_id).await?;

    if req.images.is_empty() {
        return Err(ApiError::BadRequest("no images given"));
    }
    if req.images.len() > bulk::MAX_BULK_IMAGES {
        return Err(ApiError::BadRequest("too many images in one request"));
    }

    let mut items = Vec::with_capacity(req.images.len());
    let mut total_bytes: u64 = 0;
    for image in req.images {
        let bytes = BASE64
            .decode(&image.data)
            .map_err(|_| ApiError::BadRequest("image data must be base64"))?;
        total_bytes = total_bytes.saturating_add(bytes.len() as u64);
        items.push((image.name, bytes));
    }
    if total_bytes > bulk::MAX_BULK_TOTAL_BYTES {
        return Err(ApiError::BadRequest("too much image data in one request"));
    }

    super::attachments::room_for(&state, total_bytes as i64).await?;

    let created = bulk::add_emoji_bulk(&state.store, &state.media, items, Some(ctx.user_id))
        .await
        .map_err(bulk_refusal)?;

    Ok((
        StatusCode::CREATED,
        Json(
            created
                .into_iter()
                .map(|e| CustomEmojiDto {
                    id: e.id,
                    name: e.name,
                    uploader_id: e.uploader_id,
                    created_at: e.created_at,
                    same_image_as: None,
                })
                .collect(),
        ),
    ))
}

/// Anything about one image in the batch reuses [`refusal`], so a name
/// collision or a bad image answers exactly the way the single upload would.
fn bulk_refusal(err: BulkAddError) -> ApiError {
    match err {
        BulkAddError::Item { error, .. } => refusal(error),
        BulkAddError::Storage(err) => {
            tracing::error!(error = %err, "failed to store a bulk-uploaded emoji");
            ApiError::Internal
        }
    }
}

/// The status code each refusal deserves. Everything up to [`AddError::Full`]
/// is something about this request; storage failure is about this server.
fn refusal(err: AddError) -> ApiError {
    match err {
        AddError::UnusableName => {
            ApiError::BadRequest("emoji name must be 1 to 32 characters of a-z, 0-9 or _")
        }
        AddError::Empty => ApiError::BadRequest("emoji is empty"),
        AddError::TooLarge => ApiError::BadRequest("emoji is too large"),
        AddError::UnsupportedType => ApiError::BadRequest("unsupported emoji type"),
        AddError::NameTaken => ApiError::Conflict("an emoji with that name already exists"),
        AddError::BuiltinName => {
            ApiError::Conflict("that name is a standard emoji's shortcode, pick another")
        }
        AddError::Full => ApiError::Conflict("this deployment is at its emoji limit"),
        AddError::Storage(err) => {
            tracing::error!(error = %err, "failed to store an uploaded emoji");
            ApiError::Internal
        }
    }
}

/// Removes an emoji. Idempotent: deleting one already gone is a 204, so a
/// retry never has to distinguish "gone" from "never existed".
async fn remove(
    Authed(ctx): Authed,
    parts: Parts,
    Path(emoji_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;

    let id = parse_id(&emoji_id)?;
    state.store.delete_custom_emoji(id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Serves an emoji's bytes to any authenticated caller.
async fn image(
    AuthedLimited(_ctx): AuthedLimited<ASSET>,
    Path(emoji_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let id = parse_id(&emoji_id)?;
    let sha256 = state
        .store
        .custom_emoji_sha256(id)
        .await?
        .ok_or(ApiError::NotFound("emoji not found"))?;

    let hex = media::to_hex(&sha256);
    let meta = state
        .store
        .attachment_summary(&sha256)
        .await?
        .ok_or(ApiError::NotFound("emoji not found"))?;
    let bytes = state.media.read_attachment(&hex).await.map_err(|err| {
        tracing::error!(error = %err, "failed to read a stored emoji");
        ApiError::Internal
    })?;

    // serve already applies the immutable cache header, right for a content-addressed emoji.
    Ok(serve(bytes, &meta.content_type, &meta.filename))
}

// --- Helpers ---

fn parse_id(raw: &str) -> Result<EmojiId, ApiError> {
    raw.parse::<uuid::Uuid>()
        .map(EmojiId)
        .map_err(|_| ApiError::BadRequest("invalid emoji id"))
}
