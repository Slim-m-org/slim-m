// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /auth/refresh`: rotates a session from the body's token or, for a web client, its cookie.

use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use serde::Deserialize;

use super::parse_client_info;
use super::web_session;
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::session_revocation::sessions_revoked_by_id;
use crate::ids::UserId;
use crate::store::RefreshOutcome;

#[derive(Deserialize)]
pub(super) struct RefreshRequest {
    /// Absent from a web client, whose token rides in the cookie.
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    client_kind: Option<String>,
    #[serde(default)]
    client_version: Option<String>,
}

/// Rotates a session from the body's refresh token or, for a web client, from its cookie.
pub(super) async fn rotate(
    state: &AppState,
    headers: &HeaderMap,
    req: RefreshRequest,
) -> Result<Response, ApiError> {
    let (kind, version) =
        parse_client_info(req.client_kind.as_deref(), req.client_version.as_deref())?;
    let web = web_session::requested(headers);
    let account = web_session::account(headers);
    let token = match (req.refresh_token, web) {
        (Some(token), false) => token,
        (None, false) => {
            return Err(ApiError::BadRequestDetail(
                "missing field `refresh_token`".to_owned(),
            ));
        }
        (Some(token), true) if !token.is_empty() => token,
        (_, true) => match account.and_then(|id| web_session::read_cookie(headers, id)) {
            Some(token) => token,
            None => return Ok(refused(headers, account)),
        },
    };
    let outcome = state
        .store
        .rotate_refresh_reporting(&token, kind.as_deref(), version.as_deref())
        .await?;
    match outcome {
        RefreshOutcome::Rotated(tokens) => {
            tracing::debug!(user_id = %tokens.user_id, device_id = %tokens.device_id, "auth: session refreshed");
            Ok(web_session::session_response(headers, &tokens))
        }
        // A benign miss and a detected replay look the same: the only move is to sign in again.
        RefreshOutcome::Denied(_) => Ok(refused(headers, account)),
        RefreshOutcome::Reused(session_id) => {
            sessions_revoked_by_id(state, vec![session_id]);
            Ok(refused(headers, account))
        }
    }
}

/// A 401 that also drops a web client's dead cookie, so it stops presenting it.
fn refused(headers: &HeaderMap, account: Option<UserId>) -> Response {
    let response = ApiError::Unauthorized.into_response();
    match account {
        Some(user_id) => web_session::clearing(headers, user_id, response),
        None => response,
    }
}
