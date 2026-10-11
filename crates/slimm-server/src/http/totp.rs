// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The optional TOTP second factor over REST (decision 0048): enrol, confirm,
//! reissue recovery codes, disable, meet a sign-in challenge, and the
//! administrator's clear for a member who has lost both.
//!
//! Nothing here ever logs a secret, a code, or a recovery code, and the wire
//! types carrying them are not `Debug` for the same reason
//! [`crate::store::IssuedTokens`] is not.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AuthedLimited, Bytes, Json, PASSWORD, RateLimited, TOTP, WRITE};
use super::messages::parse_uuid;
use super::reauth::require_password;
use crate::hub::Event;
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::store::{ChallengeError, TotpError, TotpProof};

const BODY_LIMIT: usize = 4 * 1024;

/// Said the same way for a wrong code, a replayed code and a code just outside
/// the window, so a caller cannot learn which of the three it was and narrow
/// the next guess.
const BAD_CODE: &str = "that code is not valid";

/// The TOTP routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/auth/totp", get(status))
        .route("/auth/totp/enrol", post(enrol))
        .route("/auth/totp/confirm", post(confirm))
        .route("/auth/totp/recovery-codes", post(reissue_recovery_codes))
        .route("/auth/totp/disable", post(disable))
        .route("/auth/totp/verify", post(verify))
        .route("/admin/users/{user_id}/totp", delete(admin_clear))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

// --- Wire types ---

#[derive(Serialize)]
struct StatusResponse {
    /// Confirmed, and therefore demanded at sign-in.
    enabled: bool,
    /// Enrolled but never confirmed, so not demanded at sign-in. A client
    /// showing this offers to finish setup rather than to start over.
    pending: bool,
    confirmed_at: Option<i64>,
    recovery_codes_remaining: i64,
    /// What the operator chose for this deployment, so one screen can say
    /// whether the factor is merely available or expected.
    policy: String,
}

/// Not `Debug`: the whole body is the secret.
#[derive(Serialize)]
struct EnrolmentResponse {
    secret: String,
    provisioning_uri: String,
}

#[derive(Deserialize)]
struct EnrolRequest {
    #[serde(default)]
    password: Option<String>,
}

#[derive(Deserialize)]
struct ConfirmRequest {
    code: String,
    #[serde(default)]
    password: Option<String>,
}

#[derive(Deserialize)]
struct CodeRequest {
    code: String,
}

/// Not `Debug`: shown to the member once and never retrievable again.
#[derive(Serialize)]
struct RecoveryCodesResponse {
    recovery_codes: Vec<String>,
}

#[derive(Deserialize)]
struct VerifyRequest {
    challenge: String,
    /// An authenticator code or one of the recovery codes; the server tries
    /// both rather than making the client say which it holds.
    code: String,
    /// The install id the login request would have carried; the challenge
    /// row does not store one.
    #[serde(default)]
    install_id: Option<String>,
}

// --- Handlers ---

async fn status(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    State(state): State<AppState>,
) -> Result<Json<StatusResponse>, ApiError> {
    let status = state.store.totp_status(ctx.user_id).await?;
    Ok(Json(StatusResponse {
        enabled: status.enabled,
        pending: status.pending,
        confirmed_at: status.confirmed_at,
        recovery_codes_remaining: status.recovery_codes_remaining,
        policy: state.store.totp_policy().await?.as_str().to_owned(),
    }))
}

/// Starts an enrolment and hands back the secret once, as text and as an
/// `otpauth://` URI the client renders as a QR code.
///
/// Nothing is enforced yet: the factor is not live until
/// [`confirm`] verifies a code from it, which is what stops a mis-scanned QR or
/// an unsynced clock from locking somebody out of their own account.
async fn enrol(
    AuthedLimited(ctx): AuthedLimited<PASSWORD>,
    State(state): State<AppState>,
    Json(body): Json<EnrolRequest>,
) -> Result<Json<EnrolmentResponse>, ApiError> {
    require_password(&state, ctx.user_id, body.password.as_deref()).await?;
    let account = state
        .store
        .user_profile(ctx.user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?
        .username;
    // The deployment, not the product: somebody in two communities has to tell their two authenticator entries apart.
    let issuer = state.store.deployment_name().await?;
    let enrolment = state
        .store
        .begin_totp_enrolment(ctx.user_id, &issuer, &account)
        .await
        .map_err(enrolment_error)?;
    Ok(Json(EnrolmentResponse {
        secret: enrolment.secret,
        provisioning_uri: enrolment.provisioning_uri,
    }))
}

/// Switches the factor on, against a code proving the authenticator holds the
/// secret, and hands over the recovery codes.
async fn confirm(
    AuthedLimited(ctx): AuthedLimited<TOTP>,
    State(state): State<AppState>,
    Json(body): Json<ConfirmRequest>,
) -> Result<Json<RecoveryCodesResponse>, ApiError> {
    require_password(&state, ctx.user_id, body.password.as_deref()).await?;
    let recovery_codes = state
        .store
        .confirm_totp_enrolment(ctx.user_id, body.code.trim())
        .await
        .map_err(factor_error)?;
    Ok(Json(RecoveryCodesResponse { recovery_codes }))
}

/// Replaces the recovery set, against current proof. The previous codes stop
/// working, which is the point: a set somebody has lost track of should not stay
/// live beside the set they just wrote down.
async fn reissue_recovery_codes(
    AuthedLimited(ctx): AuthedLimited<TOTP>,
    State(state): State<AppState>,
    Json(body): Json<CodeRequest>,
) -> Result<Json<RecoveryCodesResponse>, ApiError> {
    state
        .store
        .verify_totp_for_change(ctx.user_id, body.code.trim())
        .await
        .map_err(factor_error)?;
    let recovery_codes = state
        .store
        .regenerate_totp_recovery_codes(ctx.user_id)
        .await
        .map_err(factor_error)?;
    Ok(Json(RecoveryCodesResponse { recovery_codes }))
}

/// Turns the factor off, against a current code or an unused recovery code.
///
/// Sessions are left alone on purpose: the caller has just proved both factors,
/// so signing their other devices out would be a penalty for housekeeping. See
/// decision 0048, and [`admin_clear`] for the path that does revoke.
async fn disable(
    AuthedLimited(ctx): AuthedLimited<TOTP>,
    State(state): State<AppState>,
    Json(body): Json<CodeRequest>,
) -> Result<StatusCode, ApiError> {
    state
        .store
        .verify_totp_for_change(ctx.user_id, body.code.trim())
        .await
        .map_err(factor_error)?;
    state
        .store
        .remove_totp_factor(ctx.user_id)
        .await
        .map_err(factor_error)?;
    Ok(StatusCode::NO_CONTENT)
}

/// Completes a sign-in that `/auth/login` answered with a challenge.
///
/// Unauthenticated, like `/auth/reset`: the caller has no session yet, which is
/// the whole reason they are here. The challenge is the authorization, and the
/// device fields come from the login request it was minted for rather than from
/// this body.
async fn verify(
    _limited: RateLimited<TOTP>,
    State(state): State<AppState>,
    Json(body): Json<VerifyRequest>,
) -> Result<Json<super::auth::TokenResponse>, ApiError> {
    let install_id = super::auth::parse_install_id(body.install_id.as_deref())?;
    let signed_in = state
        .store
        .complete_totp_challenge(&body.challenge, body.code.trim(), install_id.as_deref())
        .await
        .map_err(challenge_error)?;

    super::sign_in_alert::announce(
        &state,
        &signed_in.tokens,
        &signed_in.device_name,
        signed_in.client_kind.as_deref(),
    )
    .await;
    if signed_in.proof == TotpProof::RecoveryCode {
        // That one was spent, never which: an operator needs to know a recovery path was used.
        tracing::info!(
            user_id = %signed_in.tokens.user_id,
            remaining = signed_in.recovery_codes_remaining,
            "a sign-in spent a TOTP recovery code"
        );
    }
    Ok(Json(super::auth::token_response(&signed_in.tokens)))
}

/// Clears another member's factor. Requires ADMINISTRATOR.
///
/// Deliberately its own permission-gated act rather than something an
/// admin-issued password reset does on the way past: a reset code answers "I
/// forgot my password" and this answers "I lost my authenticator", and decision
/// 0048 records why collapsing the two would make the factor worth no more than
/// one administrator's say-so. It revokes every session and writes a
/// `totp_cleared` audit entry, so the act leaves a trace that outlives it.
async fn admin_clear(
    AuthedLimited(ctx): AuthedLimited<PASSWORD>,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<StatusCode, ApiError> {
    super::extract::require_base_permission(&state, ctx.user_id, Permissions::ADMINISTRATOR)
        .await?;
    super::reauth::require_admin_password(&state, ctx.user_id, &body).await?;
    let user_id = UserId(parse_uuid(&user_id)?);
    let revoked = state
        .store
        .clear_totp_factor(Some(ctx.user_id), user_id)
        .await
        .map_err(|err| match err {
            TotpError::NotEnrolled => {
                ApiError::NotFound("that member has no second factor to clear")
            }
            other => factor_error(other),
        })?;
    for session_id in revoked {
        state.hub.publish(Event::SessionRevoked(session_id));
    }
    Ok(StatusCode::NO_CONTENT)
}

// --- Error mapping ---

fn enrolment_error(err: TotpError) -> ApiError {
    match err {
        TotpError::PolicyForbids => {
            ApiError::ForbiddenBecause("this server does not accept new two-factor enrolments")
        }
        TotpError::AlreadyEnabled => ApiError::Conflict(
            "two-factor authentication is already on; turn it off before enrolling again",
        ),
        other => factor_error(other),
    }
}

/// A lockout is the one refusal that does not answer like the others, and that
/// is a considered trade: telling somebody "wait, you are locked out" discloses
/// that this account has a factor and has been guessed at, which a determined
/// attacker learns anyway by being locked out themselves. Hiding it instead
/// means a member who mistyped five codes sees "that code is not valid" for a
/// correct code and concludes their authenticator is broken.
pub(super) fn factor_error(err: TotpError) -> ApiError {
    match err {
        TotpError::NotEnrolled | TotpError::NotConfirmed => {
            ApiError::BadRequest("two-factor authentication is not set up on this account")
        }
        TotpError::AlreadyEnabled => ApiError::Conflict("two-factor authentication is already on"),
        TotpError::PolicyForbids => {
            ApiError::ForbiddenBecause("this server does not accept new two-factor enrolments")
        }
        TotpError::BadCode => ApiError::BadRequest(BAD_CODE),
        TotpError::Locked { .. } => ApiError::TooManyRequests,
        TotpError::Internal(err) => err.into(),
    }
}

fn challenge_error(err: ChallengeError) -> ApiError {
    match err {
        // One answer for unknown, expired, spent and factor-gone, so this cannot mine which challenges are live.
        ChallengeError::Unusable => ApiError::Unauthorized,
        ChallengeError::BadCode => ApiError::BadRequest(BAD_CODE),
        ChallengeError::Locked { .. } => ApiError::TooManyRequests,
        ChallengeError::Open(open) => open.into(),
        ChallengeError::Internal(err) => err.into(),
    }
}

/// The challenge body `/auth/login` answers with when a second factor is owed.
///
/// A `202` rather than a field added to the token response: the sign-in has not
/// completed, so promising a client the token fields and then omitting them
/// would make every existing reader's "read `access_token`" a crash. See
/// `schema/openapi.yaml`.
#[derive(Serialize)]
pub(super) struct ChallengeResponse {
    pub(super) totp_challenge: String,
    pub(super) expires_at: i64,
}

impl IntoResponse for ChallengeResponse {
    fn into_response(self) -> Response {
        (StatusCode::ACCEPTED, axum::Json(self)).into_response()
    }
}
