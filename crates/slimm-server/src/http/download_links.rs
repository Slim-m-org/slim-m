// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Short-lived signed download links, so a browser saves a large file natively.
//!
//! A web client cannot stream a bearer-authenticated response to disk, and buffers the whole file
//! in memory instead. A link names one attachment or export for one user and expires in a minute;
//! redeeming it re-runs the same permission checks as the authenticated route, so a link never
//! outlives a lost permission by more than its lifetime.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::http::{HeaderMap, HeaderValue, header};
use axum::response::Response;
use axum::routing::{get, post};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use uuid::Uuid;

use super::AppState;
use super::attachments::{self, FetchParams};
use super::data_exports;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, enforce};
use crate::ids::UserId;
use crate::ratelimit::Class;
use crate::store::now_ms;

/// Long enough for the browser to follow the link, short enough that a copied one is of little use.
const LINK_TTL_MS: i64 = 60 * 1000;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/downloads/links", post(mint))
        .route("/downloads/{token}", get(redeem))
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum Target {
    Attachment {
        id: String,
        #[serde(default)]
        original: bool,
    },
    Export {
        id: String,
    },
}

#[derive(Serialize, Deserialize)]
struct Claims {
    user: String,
    target: Target,
    expires_at: i64,
}

fn seal(key: &[u8; 32], claims: &Claims) -> String {
    let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap_or_default());
    let mut mac = <Hmac<Sha256>>::new_from_slice(key).expect("hmac takes any key length");
    mac.update(payload.as_bytes());
    let tag = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    format!("{payload}.{tag}")
}

fn open(key: &[u8; 32], token: &str, now: i64) -> Option<Claims> {
    let (payload, tag) = token.split_once('.')?;
    let tag = URL_SAFE_NO_PAD.decode(tag).ok()?;
    let mut mac = <Hmac<Sha256>>::new_from_slice(key).ok()?;
    mac.update(payload.as_bytes());
    mac.verify_slice(&tag).ok()?;
    let claims: Claims = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).ok()?).ok()?;
    (claims.expires_at > now).then_some(claims)
}

#[derive(Serialize)]
struct LinkDto {
    /// Server-relative, to open in the browser as is.
    path: String,
    expires_at: i64,
}

/// A link for something the caller may download right now; anything else reads as missing.
async fn mint(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
    Json(target): Json<Target>,
) -> Result<Json<LinkDto>, ApiError> {
    match &target {
        Target::Attachment { id, .. } => {
            let sha256 = attachments::parse_attachment_id(id)?;
            if !attachments::may_fetch(&state, ctx.user_id, &sha256).await? {
                return Err(ApiError::NotFound("attachment not found"));
            }
        }
        Target::Export { id } => {
            data_exports::downloadable(&state, ctx.user_id, id).await?;
        }
    }
    let expires_at = now_ms() + LINK_TTL_MS;
    let claims = Claims {
        user: ctx.user_id.to_string(),
        target,
        expires_at,
    };
    let key = state.store.download_link_key().await?;
    Ok(Json(LinkDto {
        path: format!("/downloads/{}", seal(&key, &claims)),
        expires_at,
    }))
}

/// Serves what the link names as a forced download, with range support so the browser can resume.
async fn redeem(
    parts: Parts,
    Path(token): Path<String>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    enforce(&state, &parts, None, Class::Asset)?;
    let key = state.store.download_link_key().await?;
    let claims = open(&key, &token, now_ms()).ok_or(ApiError::NotFound("download link expired"))?;
    let user_id = UserId(
        Uuid::parse_str(&claims.user).map_err(|_| ApiError::NotFound("download link expired"))?,
    );
    let mut response = match claims.target {
        Target::Attachment { id, original } => {
            let params = FetchParams::whole(original);
            attachments::serve_for(&state, user_id, &id, params, &headers).await?
        }
        Target::Export { id } => data_exports::serve_for(&state, user_id, &id, &headers).await?,
    };
    force_attachment(&mut response);
    Ok(response)
}

/// A browser renders an inline type instead of saving it, which is not what a download link is for.
fn force_attachment(response: &mut Response) {
    let headers = response.headers_mut();
    let Some(value) = headers.get(header::CONTENT_DISPOSITION) else {
        return;
    };
    let Some(rest) = value.to_str().ok().and_then(|v| v.strip_prefix("inline")) else {
        return;
    };
    if let Ok(forced) = HeaderValue::from_str(&format!("attachment{rest}")) {
        headers.insert(header::CONTENT_DISPOSITION, forced);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; 32] = [3; 32];

    fn claims(expires_at: i64) -> Claims {
        Claims {
            user: Uuid::nil().to_string(),
            target: Target::Export { id: "e".into() },
            expires_at,
        }
    }

    #[test]
    fn a_sealed_link_opens_until_it_expires() {
        let token = seal(&KEY, &claims(1_000));
        assert!(open(&KEY, &token, 999).is_some());
        assert!(open(&KEY, &token, 1_000).is_none());
    }

    #[test]
    fn a_link_signed_by_another_key_or_edited_is_refused() {
        let token = seal(&KEY, &claims(1_000));
        assert!(open(&[4; 32], &token, 0).is_none());
        let (_, tag) = token.split_once('.').unwrap();
        let forged = seal(&KEY, &claims(9_999_999));
        let (payload, _) = forged.split_once('.').unwrap();
        assert!(open(&KEY, &format!("{payload}.{tag}"), 0).is_none());
        assert!(open(&KEY, "nonsense", 0).is_none());
    }
}
