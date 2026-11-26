// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The browser's refresh token lives in an HttpOnly cookie, never in a body (decision 0141).
//!
//! A web client opts in with the `x-slimm-web-session: cookie` header. Every other client is untouched.
//! The cookie name carries the account, so several accounts in one browser never share a cookie.

use axum::http::header::{COOKIE, SET_COOKIE};
use axum::http::{HeaderMap, HeaderValue};
use axum::response::{IntoResponse, Response};
use uuid::Uuid;

use super::{TokenResponse, token_response};
use crate::http::extract::Json;
use crate::ids::UserId;
use crate::store::IssuedTokens;

/// Present with the value [`WEB_SESSION_VALUE`] on every call that mints, rotates or ends a browser session.
///
/// A custom header cannot ride a cross-site form post, which is what makes the cookie refresh safe from CSRF.
const WEB_SESSION_HEADER: &str = "x-slimm-web-session";
const WEB_SESSION_VALUE: &str = "cookie";
/// Names which account's cookie a refresh reads.
const ACCOUNT_HEADER: &str = "x-slimm-account";
/// `__Host-` makes the browser refuse a cookie set from a sibling subdomain; it needs `Path=/` and no `Domain`.
const COOKIE_PREFIX: &str = "__Host-slimm_rt_";

/// Whether the caller is a web client that keeps its refresh token in the cookie.
pub(in crate::http) fn requested(headers: &HeaderMap) -> bool {
    headers
        .get(WEB_SESSION_HEADER)
        .is_some_and(|value| value.as_bytes() == WEB_SESSION_VALUE.as_bytes())
}

/// The account a cookie refresh names, if the header is a well-formed id.
pub(super) fn account(headers: &HeaderMap) -> Option<UserId> {
    let raw = headers.get(ACCOUNT_HEADER)?.to_str().ok()?;
    Uuid::parse_str(raw.trim()).ok().map(UserId)
}

fn cookie_name(user_id: UserId) -> String {
    format!("{COOKIE_PREFIX}{user_id}")
}

/// The refresh token in `user_id`'s cookie, if the browser sent one.
pub(super) fn read_cookie(headers: &HeaderMap, user_id: UserId) -> Option<String> {
    let wanted = cookie_name(user_id);
    headers
        .get_all(COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|line| line.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .find(|(name, _)| *name == wanted)
        .map(|(_, value)| value.to_owned())
        .filter(|value| !value.is_empty())
}

fn cookie_line(user_id: UserId, value: &str, max_age_secs: i64) -> HeaderValue {
    let name = cookie_name(user_id);
    let line = format!(
        "{name}={value}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age={max_age_secs}"
    );
    HeaderValue::from_str(&line).expect("a uuid and an opaque token are header-safe")
}

fn session_cookie(tokens: &IssuedTokens) -> HeaderValue {
    let remaining_ms = tokens.refresh_expires_at - crate::store::now_ms();
    cookie_line(
        tokens.user_id,
        &tokens.refresh_token,
        (remaining_ms / 1000).max(0),
    )
}

/// Asks the browser to drop `user_id`'s cookie.
pub(in crate::http) fn clear_cookie(user_id: UserId) -> HeaderValue {
    cookie_line(user_id, "", 0)
}

/// Adds the cookie-clearing header to `response` when the caller is a web client.
pub(in crate::http) fn clearing(
    headers: &HeaderMap,
    user_id: UserId,
    mut response: Response,
) -> Response {
    if requested(headers) {
        response
            .headers_mut()
            .append(SET_COOKIE, clear_cookie(user_id));
    }
    response
}

/// The reply to a call that minted or rotated a session.
///
/// A web client gets the refresh token as a cookie and no body field; everyone else gets today's body.
pub(in crate::http) fn session_response(headers: &HeaderMap, tokens: &IssuedTokens) -> Response {
    let mut body: TokenResponse = token_response(tokens);
    if !requested(headers) {
        return Json(body).into_response();
    }
    body.refresh_token = None;
    let mut response = Json(body).into_response();
    response
        .headers_mut()
        .append(SET_COOKIE, session_cookie(tokens));
    response
}
