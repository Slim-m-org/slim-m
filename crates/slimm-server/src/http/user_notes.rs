// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A caller's private note about another account.
//!
//! Caller-private, always: a note is visible only to the author who wrote
//! it, never to the subject, never to another member, and there is no
//! moderation surface for it - unlike `safety.rs`'s blocking relation, this
//! has no second direction anyone queries.
//!
//! Masked exactly like `getUser`/`getAvatar` (`http/users.rs`): a subject id
//! with nothing live to answer for - never registered, or since deleted or
//! anonymized - refuses identically to a real account the caller has simply
//! never noted, per decision 0011's masking rule
//! (`docs/decisions/0011-per-channel-permissions.md`), so this can never be
//! used to confirm whether a subject id names a real, currently-visible
//! account.
//!
//! Purged with the author's own account deletion
//! ([`crate::store::Store::delete_account`]), not the subject's, because the
//! note is the author's data; see migration 0055's own comment.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, WRITE};
use super::hidden_chars::is_hidden_in_prose;
use super::messages::parse_uuid;
use crate::ids::UserId;
use crate::store::UserNote;

const BODY_LIMIT: usize = 2 * 1024;

/// A note is a short private annotation, not a document - well under the
/// smallest existing free-text cap (`STATUS_TEXT_MAX_CHARS` at 80) would be
/// too tight for a sentence of context, so this sits with `topic` (256) and
/// `display_name` (64) rather than with a message body.
const MAX_NOTE_CHARS: usize = 500;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/users/{user_id}/note", get(get_note).put(put_note))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct UserNoteDto {
    body: Option<String>,
    updated_at: Option<i64>,
}

impl From<Option<UserNote>> for UserNoteDto {
    fn from(note: Option<UserNote>) -> Self {
        match note {
            Some(note) => Self {
                body: Some(note.body),
                updated_at: Some(note.updated_at),
            },
            None => Self {
                body: None,
                updated_at: None,
            },
        }
    }
}

#[derive(Deserialize)]
struct PutNoteRequest {
    body: String,
}

/// The one check both handlers share: refuses a self-target, then masks a
/// subject with nothing live to answer for identically to "not found" - see
/// this module's own doc comment for why the order is safe (a self-check
/// never leaks anything about anyone else).
async fn authorize_subject(
    state: &AppState,
    caller: UserId,
    subject: UserId,
) -> Result<(), ApiError> {
    if subject == caller {
        return Err(ApiError::BadRequest(
            "you cannot leave a note about yourself",
        ));
    }
    if state.store.user_profile(subject).await?.is_none() {
        return Err(ApiError::NotFound("user not found"));
    }
    Ok(())
}

async fn get_note(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<UserNoteDto>, ApiError> {
    let subject = UserId(parse_uuid(&user_id)?);
    authorize_subject(&state, ctx.user_id, subject).await?;
    let note = state.store.user_note(ctx.user_id, subject).await?;
    Ok(Json(note.into()))
}

async fn put_note(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<PutNoteRequest>,
) -> Result<Json<UserNoteDto>, ApiError> {
    let subject = UserId(parse_uuid(&user_id)?);
    authorize_subject(&state, ctx.user_id, subject).await?;

    let trimmed = req.body.trim();
    if trimmed.chars().count() > MAX_NOTE_CHARS {
        return Err(ApiError::BadRequest("that note is too long"));
    }
    if trimmed.chars().any(is_hidden_in_prose) {
        return Err(ApiError::BadRequest(
            "that note must not contain control or invisible characters",
        ));
    }
    let body = (!trimmed.is_empty()).then_some(trimmed);
    let note = state
        .store
        .set_user_note(ctx.user_id, subject, body)
        .await?;
    Ok(Json(note.into()))
}
