// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Admin-issued password reset: the self-hosted account recovery path chosen
//! in place of email. An administrator issues a one-time code for a locked-out
//! account; whoever holds it spends it once, here, to set a new password.
//!
//! Consuming a code revokes every live session on the account and closes any
//! open WebSocket on them, the same as logout and account deletion do,
//! because the point of this path is recovering an account that may be
//! compromised, not just changing its password out from under a session an
//! attacker still holds. Issuing and consuming are deliberately two different
//! trust levels: issuing needs ADMINISTRATOR, consuming needs nothing but the
//! code itself, since the person redeeming it is, by definition, someone who
//! cannot sign in right now.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::routing::post;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::auth::validate_password;
use super::error::ApiError;
use super::extract::{AuthedLimited, Bytes, Json, PASSWORD, RateLimited};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::store::{ConsumeResetError, IssueResetError};

const BODY_LIMIT: usize = 4 * 1024;

/// The recovery routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/admin/users/{user_id}/reset-code", post(issue))
        .route("/auth/reset", post(reset))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct ResetCodeIssued {
    code: String,
    expires_at: i64,
}

#[derive(Deserialize)]
struct ResetRequest {
    code: String,
    new_password: String,
}

/// Issues a one-time reset code for another account. Requires ADMINISTRATOR.
///
/// A person must also send their own password: a reset code is a way into any
/// account, so a stolen administrator token alone must not be able to mint one.
async fn issue(
    AuthedLimited(ctx): AuthedLimited<PASSWORD>,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<Json<ResetCodeIssued>, ApiError> {
    super::extract::require_base_permission(&state, ctx.user_id, Permissions::ADMINISTRATOR)
        .await?;
    super::reauth::require_admin_password(&state, ctx.user_id, &body).await?;

    let user_id = UserId(parse_uuid(&user_id)?);
    match state.store.issue_reset_code(ctx.user_id, user_id).await {
        Ok((code, expires_at)) => Ok(Json(ResetCodeIssued { code, expires_at })),
        Err(IssueResetError::NoSuchUser) => Err(ApiError::NotFound("user not found")),
        Err(IssueResetError::Internal(e)) => Err(e.into()),
    }
}

/// Spends a reset code, unauthenticated: the whole point is recovering an
/// account that cannot currently sign in. Rate limited on the same tight
/// budget as login, since a code is a guessable-length secret an attacker
/// would otherwise be free to grind.
///
/// The code is checked before the password is hashed, the way `register`'s
/// invite gate is, so a garbage code costs one indexed lookup instead of a
/// 19 MiB Argon2id run and one of only four hashing permits. Without that
/// ordering a handful of requests can hold every permit that a legitimate
/// login needs.
///
/// This does trade one thing away and it is worth naming rather than glossing:
/// a valid code now takes visibly longer to answer than an invalid one, where
/// before both paid the hash. That is a real distinguisher, and it is an
/// acceptable one - a code is 256 bits, so anybody who can tell a live code
/// from a dead one by timing already had to guess a live code to do it, and at
/// that point the oracle tells them nothing they did not just prove. The answer
/// itself stays uniform across unknown, expired and already-used.
async fn reset(
    _limited: RateLimited<PASSWORD>,
    State(state): State<AppState>,
    Json(req): Json<ResetRequest>,
) -> Result<StatusCode, ApiError> {
    validate_password(&req.new_password)?;

    // Advisory and racy; consume_reset_code re-checks and alone spends a code.
    if !state.store.reset_code_is_live(&req.code).await? {
        return Err(ApiError::BadRequest("that reset code cannot be used"));
    }

    let hash = state.auth.hash_password(req.new_password).await?;

    match state.store.consume_reset_code(&req.code, &hash).await {
        Ok(revoked) => {
            for session_id in revoked {
                state.hub.publish(Event::SessionRevoked(session_id));
            }
            Ok(StatusCode::NO_CONTENT)
        }
        // One answer whether the code was unknown, expired, or already used,
        // so this cannot be used to mine which codes are still live.
        Err(ConsumeResetError::Unusable) => {
            Err(ApiError::BadRequest("that reset code cannot be used"))
        }
        Err(ConsumeResetError::Internal(e)) => Err(e.into()),
    }
}
