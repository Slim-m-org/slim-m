// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A linked account's picture: copied once at link time through the guarded
//! outbound client, then served from disk so no viewer's device ever contacts
//! the provider's CDN.

use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::header::CONTENT_TYPE;
use axum::response::Response;

use super::AppState;
use super::attachments::serve;
use super::error::ApiError;
use super::extract::{ASSET, AuthedLimited};
use super::messages::parse_uuid;
use crate::ids::UserId;
use crate::media::{self, Motion};
use crate::net_guard::{self, GuardResolver};

const MAX_AVATAR_BYTES: usize = 1024 * 1024;
const FETCH_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_HASH_CHARS: usize = 64;

/// The client that fetches provider pictures. Redirects are refused outright:
/// a CDN avatar URL never needs one, and following one would need the
/// per-hop address checks the link preview fetcher carries.
pub(super) fn build_client(allow_private: bool) -> reqwest::Client {
    reqwest::Client::builder()
        .dns_resolver(Arc::new(GuardResolver { allow_private }))
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(FETCH_TIMEOUT)
        .build()
        .expect("a client with no unusual TLS config always builds")
}

/// The picture at `url`, or `None` when it is missing, not a still image, or
/// over the size cap. Never an error: a link is worth keeping without one.
pub(super) async fn fetch(client: &reqwest::Client, url: &str) -> Option<Vec<u8>> {
    let response = client.get(url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let is_image = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.to_ascii_lowercase().starts_with("image/"));
    if !is_image {
        return None;
    }
    let bytes = net_guard::read_capped(response, MAX_AVATAR_BYTES)
        .await
        .ok()?;
    media::check_image(&bytes, Motion::StillOnly, media::MAX_PROFILE_IMAGE_SIDE).ok()?;
    media::sniff_content_type(&bytes)?;
    Some(bytes)
}

/// Whether `id` and `hash` are safe to put in a CDN path.
pub(super) fn is_path_safe(id: &str, hash: &str) -> bool {
    !id.is_empty()
        && id.bytes().all(|b| b.is_ascii_digit())
        && !hash.is_empty()
        && hash.len() <= MAX_HASH_CHARS
        && hash.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

pub(super) async fn get_discord_avatar(
    AuthedLimited(_ctx): AuthedLimited<ASSET>,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let user_id = UserId(parse_uuid(&user_id)?);
    if !state
        .store
        .has_linked_avatar(user_id, super::linked_accounts::PROVIDER)
        .await?
    {
        return Err(ApiError::NotFound("no linked picture"));
    }
    let bytes = state
        .media
        .read_linked_avatar(super::linked_accounts::PROVIDER, &user_id.to_string())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to read a stored linked picture");
            ApiError::Internal
        })?;
    let content_type = media::sniff_content_type(&bytes).ok_or(ApiError::Internal)?;
    Ok(serve(bytes, content_type, "avatar"))
}
