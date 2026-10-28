// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Auth HTTP routes: register, login, refresh, connect-ticket, and logout.
//!
//! The durable mechanics live in [`crate::store`] and [`crate::auth`]; this
//! module is the thin REST skin over them, plus input validation, the bearer
//! extractor, and the error-to-status mapping.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{delete, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::device_client_info::validate_client_info;
use super::error::ApiError;
use super::extract::{
    Authed, AuthedLimited, Json, PASSWORD, REFRESH, RateLimited, WRITE, enforce, limit_key,
};
use super::invites::invite_code_key;
use crate::hub::Event;
use crate::ratelimit::Class;
use crate::store::DeleteAccountError;
use crate::store::{IssuedTokens, JoinPolicy, RefreshOutcome, RegisterError};

/// Auth payloads are a handful of short fields; cap the body well below any
/// realistic request so an oversized body is rejected before it is buffered.
const AUTH_BODY_LIMIT: usize = 4 * 1024;

/// Said the same way whether the code was missing up front or the deployment
/// was claimed mid-request, so the client has one string to react to.
const INVITE_REQUIRED: &str = "an invite code is required to join this server";
const JOINS_PAUSED: &str = "this space is not taking new members right now";

/// The auth routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/auth/register", post(register))
        .route("/auth/login", post(login))
        .route("/auth/refresh", post(refresh))
        .route("/auth/ws-ticket", post(ws_ticket))
        .route("/auth/logout", post(logout))
        .route("/account", delete(delete_account))
        .layer(DefaultBodyLimit::max(AUTH_BODY_LIMIT))
}

// --- Wire types ---

#[derive(Deserialize)]
struct RegisterRequest {
    username: String,
    display_name: String,
    password: String,
    device_name: String,
    /// Required once the deployment has been claimed; ignored before that,
    /// since the first account is the one that claims it and there is nobody
    /// to have issued a code yet.
    #[serde(default)]
    invite_code: Option<String>,
    /// Coarse client kind ("ios"/"android"/"desktop"/"web") and app version,
    /// for the devices list; both absent on a client older than this field.
    #[serde(default)]
    client_kind: Option<String>,
    #[serde(default)]
    client_version: Option<String>,
    /// A random id the client generates once per install, so signing in again
    /// replaces that install's session instead of adding a device.
    #[serde(default)]
    install_id: Option<String>,
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
    device_name: String,
    /// See `RegisterRequest::client_kind`/`client_version`.
    #[serde(default)]
    client_kind: Option<String>,
    #[serde(default)]
    client_version: Option<String>,
    /// A random id the client generates once per install, so signing in again
    /// replaces that install's session instead of adding a device.
    #[serde(default)]
    install_id: Option<String>,
}

/// A session token alone never deletes an account: it needs the password, and a
/// current code while a second factor is on (decision 0048).
#[derive(Deserialize)]
struct DeleteAccountRequest {
    #[serde(default)]
    password: Option<String>,
    #[serde(default)]
    code: Option<String>,
}

#[derive(Deserialize)]
struct RefreshRequest {
    refresh_token: String,
    #[serde(default)]
    client_kind: Option<String>,
    #[serde(default)]
    client_version: Option<String>,
}

/// Shared with [`super::totp`], which mints the same pair once a sign-in has
/// met its second factor.
#[derive(Serialize)]
pub(super) struct TokenResponse {
    user_id: String,
    access_token: String,
    refresh_token: String,
    access_expires_at: i64,
}

/// What `login` answers with, since an account with a second factor gets a
/// challenge instead of a session.
///
/// Two response codes rather than one shape with optional token fields: a
/// reader that has always been able to count on `access_token` being there
/// should keep being able to, and `202 Accepted` says exactly what happened -
/// the password was accepted and the sign-in is not finished.
enum LoginOutcome {
    Tokens(TokenResponse),
    Challenge(super::totp::ChallengeResponse),
}

impl axum::response::IntoResponse for LoginOutcome {
    fn into_response(self) -> axum::response::Response {
        match self {
            LoginOutcome::Tokens(tokens) => Json(tokens).into_response(),
            LoginOutcome::Challenge(challenge) => challenge.into_response(),
        }
    }
}

#[derive(Serialize)]
struct TicketResponse {
    ticket: String,
    expires_at: i64,
}

/// Validates the `client_kind`/`client_version` pair register and login both
/// accept, so neither handler repeats the same two `validate_client_info`
/// calls.
fn parse_client_info(
    kind: Option<&str>,
    version: Option<&str>,
) -> Result<(Option<String>, Option<String>), ApiError> {
    Ok((
        kind.map(|v| validate_client_info(v, 16))
            .transpose()?
            .flatten(),
        version
            .map(|v| validate_client_info(v, 32))
            .transpose()?
            .flatten(),
    ))
}

/// Bounds `install_id` to what a client-minted UUID looks like, so it is
/// safe to hash and never carries anything surprising into a log.
pub(super) fn parse_install_id(value: Option<&str>) -> Result<Option<String>, ApiError> {
    let Some(value) = value.map(str::trim).filter(|v| !v.is_empty()) else {
        return Ok(None);
    };
    let ok = (8..=64).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if ok {
        Ok(Some(value.to_owned()))
    } else {
        Err(ApiError::BadRequest("install_id is not valid"))
    }
}

pub(super) fn token_response(tokens: &IssuedTokens) -> TokenResponse {
    TokenResponse {
        user_id: tokens.user_id.to_string(),
        access_token: tokens.access_token.clone(),
        refresh_token: tokens.refresh_token.clone(),
        access_expires_at: tokens.access_expires_at,
    }
}

// --- Handlers ---

/// Creates an account.
///
/// Open only until the deployment is claimed; after that, joining is by
/// invitation, which [`crate::store::Store::register_account`] applies in the
/// same transaction as the account insert. The "no code at all" case is
/// answered before hashing, so the cheapest way to hammer this endpoint does
/// not also buy an Argon2id run per attempt.
///
/// The first account to register also claims an unclaimed deployment, seeding
/// the @everyone and admin roles and a general channel. Without that a fresh
/// server has no roles and no channels, so nobody could do anything.
async fn register(
    _limited: RateLimited<PASSWORD>,
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> Result<Json<TokenResponse>, ApiError> {
    validate_username(&req.username)?;
    validate_password(&req.password)?;
    let display_name = req.display_name.trim();
    validate_label(display_name, "display_name must be 1 to 64 characters")?;
    validate_label(&req.device_name, "device_name must be 1 to 64 characters")?;
    let (client_kind, client_version) =
        parse_client_info(req.client_kind.as_deref(), req.client_version.as_deref())?;
    let install_id = parse_install_id(req.install_id.as_deref())?;

    let invite_code = req
        .invite_code
        .as_deref()
        .map(invite_code_key)
        .filter(|c| !c.is_empty());
    // Answered before hashing so a doomed request costs no Argon2id run. The
    // store re-checks both inside its transaction, which is what settles a
    // claim or a policy change racing this.
    if invite_code.is_none()
        && state.store.is_bootstrapped().await?
        && state.store.join_policy().await? == JoinPolicy::Invite
    {
        return Err(ApiError::BadRequest(INVITE_REQUIRED));
    }

    let hash = state.auth.hash_password(req.password).await?;
    let account = match state
        .store
        .register_account(&req.username, display_name, &hash, invite_code.as_deref())
        .await
    {
        Ok(account) => account,
        Err(RegisterError::UsernameTaken) => {
            return Err(ApiError::Conflict("username is already taken"));
        }
        // The deployment was claimed between the pre-check above and the
        // insert, so this registration needs a code after all.
        Err(RegisterError::InviteRequired) => return Err(ApiError::BadRequest(INVITE_REQUIRED)),
        Err(RegisterError::InviteUnusable) => {
            return Err(ApiError::BadRequest("that invite cannot be used"));
        }
        Err(RegisterError::JoinsPaused) => {
            return Err(ApiError::ForbiddenBecause(JOINS_PAUSED));
        }
        Err(RegisterError::Internal(err)) => return Err(err.into()),
    };

    state.hub.publish(Event::MemberJoined(account.id));
    super::welcome::post_welcome(&state, account.id).await;

    let tokens = state
        .store
        .open_session_as(
            account.id,
            &req.device_name,
            client_kind.as_deref(),
            client_version.as_deref(),
            install_id.as_deref(),
        )
        .await?;
    Ok(Json(token_response(&tokens)))
}

/// Verifies a password, and then either opens a session or asks for the second
/// factor.
///
/// The password check is unchanged and still runs first, including its decoy
/// hash for an unknown account: whether a second factor exists must not be
/// learnable without the password, or the challenge itself becomes a way to
/// enumerate which accounts have one.
async fn login(
    _limited: RateLimited<PASSWORD>,
    State(state): State<AppState>,
    parts: Parts,
    Json(req): Json<LoginRequest>,
) -> Result<LoginOutcome, ApiError> {
    validate_label(&req.device_name, "device_name must be 1 to 64 characters")?;
    let (client_kind, client_version) =
        parse_client_info(req.client_kind.as_deref(), req.client_version.as_deref())?;
    let install_id = parse_install_id(req.install_id.as_deref())?;
    // A credential that could never exist fails like a wrong one, so the error never teaches the policy.
    if validate_username(&req.username).is_err() || validate_password(&req.password).is_err() {
        state.auth.verify_decoy().await?;
        return Err(ApiError::Unauthorized);
    }

    let credentials = state.store.find_credentials(&req.username).await?;
    // Keyed like the limiter, so a stranger's guesses only throttle the stranger.
    let source = limit_key(&parts, None, state.limiter.trusted_hops());
    // A throttled account still runs the decoy and answers like a wrong password.
    let throttled = match &credentials {
        Some((user_id, _)) => state.store.login_throttled(*user_id, &source).await?,
        None => false,
    };
    let verified = match &credentials {
        Some((_, hash)) if !throttled => {
            state
                .auth
                .verify_password(req.password, hash.clone())
                .await?
        }
        // Spend a comparable amount of time so a missing account is not
        // distinguishable from a wrong password by response latency.
        _ => {
            state.auth.verify_decoy().await?;
            false
        }
    };

    let Some((user_id, _)) = credentials else {
        return Err(ApiError::Unauthorized);
    };
    if throttled {
        return Err(ApiError::Unauthorized);
    }
    if !verified {
        state.store.record_login_failure(user_id, &source).await?;
        return Err(ApiError::Unauthorized);
    }
    state.store.clear_login_throttle(user_id, &source).await?;

    if state.store.totp_required_at_sign_in(user_id).await? {
        let challenge = state
            .store
            .begin_totp_challenge(
                user_id,
                &req.device_name,
                client_kind.as_deref(),
                client_version.as_deref(),
            )
            .await?;
        // No alert yet: `/auth/totp/verify` announces once the factor is met, so a stolen password alone cannot spam the account.
        return Ok(LoginOutcome::Challenge(super::totp::ChallengeResponse {
            totp_challenge: challenge.challenge,
            expires_at: challenge.expires_at,
        }));
    }

    let tokens = state
        .store
        .open_session_as(
            user_id,
            &req.device_name,
            client_kind.as_deref(),
            client_version.as_deref(),
            install_id.as_deref(),
        )
        .await?;
    super::sign_in_alert::announce(&state, &tokens, &req.device_name, client_kind.as_deref()).await;
    Ok(LoginOutcome::Tokens(token_response(&tokens)))
}

async fn refresh(
    _limited: RateLimited<REFRESH>,
    State(state): State<AppState>,
    Json(req): Json<RefreshRequest>,
) -> Result<Json<TokenResponse>, ApiError> {
    let (kind, version) =
        parse_client_info(req.client_kind.as_deref(), req.client_version.as_deref())?;
    let outcome = state
        .store
        .rotate_refresh_reporting(&req.refresh_token, kind.as_deref(), version.as_deref())
        .await?;
    match outcome {
        RefreshOutcome::Rotated(tokens) => Ok(Json(token_response(&tokens))),
        // A benign miss and a detected replay look identical to the client: the
        // only move either way is to log in again.
        RefreshOutcome::Denied | RefreshOutcome::Reused => Err(ApiError::Unauthorized),
    }
}

async fn ws_ticket(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<Json<TicketResponse>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Ticket)?;
    let (ticket, expires_at) = state.store.mint_ws_ticket(&ctx).await?;
    Ok(Json(TicketResponse { ticket, expires_at }))
}

async fn logout(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    state.store.revoke_session(ctx.session_id).await?;
    // Drop any live WebSocket on this session at once, so revocation is instant
    // over the socket too, not just for the next REST call.
    state.hub.publish(Event::SessionRevoked(ctx.session_id));
    Ok(StatusCode::NO_CONTENT)
}

/// Deletes the caller's own account: purge personal data, anonymize authored
/// content, tombstone the user, and revoke every session (closing live sockets).
async fn delete_account(
    AuthedLimited(ctx): AuthedLimited<PASSWORD>,
    State(state): State<AppState>,
    Json(req): Json<DeleteAccountRequest>,
) -> Result<StatusCode, ApiError> {
    super::reauth::require_password(&state, ctx.user_id, req.password.as_deref()).await?;
    super::reauth::require_current_code(&state, ctx.user_id, req.code.as_deref()).await?;
    let revoked = match state.store.delete_account(ctx.user_id).await {
        Ok(revoked) => revoked,
        // A refusal is the caller's situation, not a server fault, so it must
        // not surface as a 500.
        Err(DeleteAccountError::WouldStrandDeployment) => {
            return Err(ApiError::Conflict(
                "you are the only administrator; appoint another before deleting your account",
            ));
        }
        Err(DeleteAccountError::UserNotFound) => return Err(ApiError::NotFound("no such account")),
        Err(DeleteAccountError::Internal(e)) => return Err(e.into()),
    };
    for session_id in revoked {
        state.hub.publish(Event::SessionRevoked(session_id));
    }
    if let Err(err) = state.media.delete_avatar(&ctx.user_id.to_string()).await {
        tracing::warn!(error = %err, "failed to delete an account's avatar file");
    }
    if let Err(err) = state
        .media
        .delete_user_banner(&ctx.user_id.to_string())
        .await
    {
        tracing::warn!(error = %err, "failed to delete an account's banner file");
    }
    super::linked_accounts::purge_avatar_files(&state, ctx.user_id).await;
    super::members::announce_member_gone(&state, ctx.user_id).await;
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) use self::validation::{
    is_disallowed_label_char, validate_label, validate_password, validate_username,
};

mod validation;

#[cfg(test)]
mod tests;
