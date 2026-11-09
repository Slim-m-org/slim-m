// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Proof that the caller holds more than a session token, for the changes a
//! stolen token must not be able to make (decision 0048): turning two-factor on,
//! deleting the account, and an administrator issuing a reset code or clearing
//! another member's two-factor.
//!
//! A wrong password is a 403, never a 401: a 401 reads to a client as "your
//! session ended" and signs the member out for mistyping.

use super::AppState;
use super::error::ApiError;
use super::totp::factor_error;
use crate::ids::UserId;

/// Refuses unless `password` is the account's current password.
///
/// Wrong guesses feed the sign-in throttle under the caller's own `u:` key, so a stolen token
/// cannot grind the password here faster than it could through `/auth/login`.
pub(super) async fn require_password(
    state: &AppState,
    user_id: UserId,
    password: Option<&str>,
) -> Result<(), ApiError> {
    let Some(password) = password.filter(|password| !password.is_empty()) else {
        return Err(ApiError::BadRequest("your password is required"));
    };
    let Some(hash) = state.store.password_hash_for(user_id).await? else {
        return Err(ApiError::ForbiddenBecause(
            "this account has no password to confirm with",
        ));
    };
    let source = format!("u:{user_id}");
    let wait_ms = state
        .store
        .login_delay_remaining_ms(user_id, &source)
        .await?;
    if wait_ms > 0 {
        return Err(ApiError::RateLimited {
            retry_after_seconds: (wait_ms as u64).div_ceil(1000),
        });
    }
    if state
        .auth
        .verify_password(password.to_owned(), hash)
        .await?
    {
        state.store.clear_login_throttle(user_id, &source).await?;
        Ok(())
    } else {
        state.store.record_login_failure(user_id, &source).await?;
        Err(ApiError::ForbiddenBecause("that password is not correct"))
    }
}

#[derive(serde::Deserialize, Default)]
struct PasswordBody {
    #[serde(default)]
    password: Option<String>,
}

/// The password gate for an administrator acting on somebody else's credentials.
///
/// A bot holds no password and authenticates with its own secret token, so it
/// passes; a person must send theirs in the JSON body, which may be empty only
/// for a bot.
pub(super) async fn require_admin_password(
    state: &AppState,
    user_id: UserId,
    body: &[u8],
) -> Result<(), ApiError> {
    if state.store.is_bot(user_id).await? {
        return Ok(());
    }
    let parsed: PasswordBody = if body.iter().all(u8::is_ascii_whitespace) {
        PasswordBody::default()
    } else {
        serde_json::from_slice(body).map_err(|_| ApiError::BadRequest("invalid JSON body"))?
    };
    require_password(state, user_id, parsed.password.as_deref()).await
}

/// Refuses unless a second factor is off, or `code` is a current code or an
/// unused recovery code for it.
pub(super) async fn require_current_code(
    state: &AppState,
    user_id: UserId,
    code: Option<&str>,
) -> Result<(), ApiError> {
    if !state.store.totp_status(user_id).await?.enabled {
        return Ok(());
    }
    let Some(code) = code.map(str::trim).filter(|code| !code.is_empty()) else {
        return Err(ApiError::BadRequest(
            "a current two-factor code is required",
        ));
    };
    state
        .store
        .verify_totp_for_change(user_id, code)
        .await
        .map_err(factor_error)?;
    Ok(())
}
