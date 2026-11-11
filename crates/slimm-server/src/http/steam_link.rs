// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Linking a Steam account through Steam's OpenID 2.0 sign-in (decision 0115).
//!
//! `/me/links/steam/start` hands back the `steamcommunity.com` login URL; the
//! browser returns to `/links/steam/callback`, which spends the one-time state,
//! then asks Steam itself to vouch for the response (`check_authentication`)
//! before trusting any field of it. Like Discord it links nothing: it holds the
//! SteamID under a handoff code for the member's own app to finish.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::{Extension, Query, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::Response;
use axum::routing::{delete, post, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::link_handoff::handoff_page;
use super::linked_accounts::{MAX_NAME_CHARS, STATE_LIFETIME_MS, STEAM, page};
use super::page_shell::respond;
use super::steam_api::SteamApi;
use crate::config::Config;
use crate::ratelimit::Class;
use crate::store::{PendingLink, now_ms};

const OPENID_URL: &str = "https://steamcommunity.com/openid/login";
const OPENID_NS: &str = "http://specs.openid.net/auth/2.0";
const IDENTIFIER_SELECT: &str = "http://specs.openid.net/auth/2.0/identifier_select";
const CLAIMED_PREFIX: &str = "https://steamcommunity.com/openid/id/";
const VERIFY_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_PARAMS: usize = 40;
const MAX_VALUE_CHARS: usize = 2048;

/// The configured Steam key and callback, or nothing when linking is off.
/// Handed to the router as an `Extension`, like `DiscordLinks`.
#[derive(Clone)]
pub struct SteamLinks {
    inner: Arc<Inner>,
    api: SteamApi,
}

struct Inner {
    redirect_uri: String,
    openid_url: String,
    http: reqwest::Client,
}

impl SteamLinks {
    /// `None` unless the API key and the redirect URI are both set.
    pub fn new(config: &Config) -> anyhow::Result<Option<Self>> {
        let (Some(key), Some(redirect)) = (
            config.steam_api_key.as_deref(),
            config.steam_redirect_uri.as_deref(),
        ) else {
            return Ok(None);
        };
        Ok(Some(Self::build(
            redirect,
            OPENID_URL,
            SteamApi::new(key)?,
        )?))
    }

    /// Points the OpenID endpoint at a local fake; tests use it.
    pub fn with_endpoints(
        redirect_uri: &str,
        openid_url: &str,
        api: SteamApi,
    ) -> anyhow::Result<Self> {
        Self::build(redirect_uri, openid_url, api)
    }

    fn build(redirect_uri: &str, openid_url: &str, api: SteamApi) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(VERIFY_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            inner: Arc::new(Inner {
                redirect_uri: redirect_uri.to_owned(),
                openid_url: openid_url.to_owned(),
                http,
            }),
            api,
        })
    }

    pub fn api(&self) -> &SteamApi {
        &self.api
    }

    fn return_to(&self, state: &str) -> String {
        format!("{}?state={state}", self.inner.redirect_uri)
    }

    fn realm(&self) -> String {
        match url::Url::parse(&self.inner.redirect_uri) {
            Ok(url) => url.origin().ascii_serialization(),
            Err(_) => self.inner.redirect_uri.clone(),
        }
    }

    fn login_url(&self, state: &str) -> String {
        let mut url = url::Url::parse(OPENID_URL).expect("a constant URL parses");
        url.query_pairs_mut()
            .append_pair("openid.ns", OPENID_NS)
            .append_pair("openid.mode", "checkid_setup")
            .append_pair("openid.return_to", &self.return_to(state))
            .append_pair("openid.realm", &self.realm())
            .append_pair("openid.identity", IDENTIFIER_SELECT)
            .append_pair("openid.claimed_id", IDENTIFIER_SELECT);
        url.into()
    }

    /// The SteamID64 a sign-in response proves, or why it proves nothing.
    /// Every field is checked here and Steam is then asked to confirm the
    /// signature; a response that fails either is not an identity.
    async fn verified_steam_id(
        &self,
        params: &HashMap<String, String>,
        state: &str,
    ) -> Result<String, &'static str> {
        let get = |k: &str| params.get(k).map(String::as_str);
        if get("openid.ns") != Some(OPENID_NS) || get("openid.mode") != Some("id_res") {
            return Err("not an OpenID response");
        }
        if get("openid.return_to") != Some(self.return_to(state).as_str()) {
            return Err("response was meant for another address");
        }
        let claimed = get("openid.claimed_id").ok_or("no identity")?;
        let steam_id = steam_id_from_claimed(claimed).ok_or("not a Steam identity")?;
        if get("openid.identity") != Some(claimed) {
            return Err("identity mismatch");
        }
        if get("openid.op_endpoint") != Some(OPENID_URL) {
            return Err("response came from another provider");
        }
        let mut form: Vec<(&str, &str)> = params
            .iter()
            .filter(|(k, _)| k.starts_with("openid."))
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .filter(|(k, _)| *k != "openid.mode")
            .collect();
        form.push(("openid.mode", "check_authentication"));
        let answer = self
            .inner
            .http
            .post(&self.inner.openid_url)
            .form(&form)
            .send()
            .await
            .map_err(|_| "Steam did not answer")?;
        if !answer.status().is_success() {
            return Err("Steam did not answer");
        }
        let text = answer.text().await.map_err(|_| "Steam did not answer")?;
        if text.lines().any(|line| line.trim() == "is_valid:true") {
            Ok(steam_id.to_owned())
        } else {
            Err("Steam did not vouch for this response")
        }
    }
}

/// `https://steamcommunity.com/openid/id/<17 digits>` to the 17 digits.
fn steam_id_from_claimed(claimed: &str) -> Option<&str> {
    let id = claimed.strip_prefix(CLAIMED_PREFIX)?;
    (id.len() == 17 && id.bytes().all(|b| b.is_ascii_digit())).then_some(id)
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/me/links/steam/start", post(start))
        .route("/me/links/steam", delete(unlink))
        .route("/me/links/steam/sharing", put(set_sharing))
        .route("/links/steam/callback", axum::routing::get(callback))
}

#[derive(Serialize)]
struct StartDto {
    url: String,
}

async fn start(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    steam: Option<Extension<SteamLinks>>,
) -> Result<Json<StartDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let Some(Extension(steam)) = steam else {
        return Err(ApiError::NotConfigured(
            "Steam linking is not set up on this server",
        ));
    };
    let link_state = crate::auth::generate_secret();
    state
        .store
        .create_link_state(
            ctx.user_id,
            STEAM,
            &link_state,
            now_ms() + STATE_LIFETIME_MS,
        )
        .await?;
    Ok(Json(StartDto {
        url: steam.login_url(&link_state),
    }))
}

async fn callback(
    State(state): State<AppState>,
    parts: Parts,
    steam: Option<Extension<SteamLinks>>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    enforce(&state, &parts, None, Class::InviteCheck)?;
    let Some(Extension(steam)) = steam else {
        return Ok(page(
            StatusCode::NOT_IMPLEMENTED,
            "Steam linking is not set up on this server.",
        ));
    };
    let bad =
        params.len() > MAX_PARAMS || params.values().any(|v| v.chars().count() > MAX_VALUE_CHARS);
    let Some(link_state) = params
        .get("state")
        .filter(|s| s.len() <= 128)
        .filter(|_| !bad)
    else {
        return Ok(page(
            StatusCode::BAD_REQUEST,
            "This link is not valid. Start again from slim-m.",
        ));
    };
    let Some(user_id) = state.store.take_link_state(link_state, STEAM).await? else {
        return Ok(page(
            StatusCode::BAD_REQUEST,
            "This link has expired or was already used. Start again from slim-m.",
        ));
    };
    if params.get("openid.mode").map(String::as_str) == Some("cancel") {
        return Ok(page(
            StatusCode::OK,
            "Linking was cancelled. You can close this tab.",
        ));
    }
    let steam_id = match steam.verified_steam_id(&params, link_state).await {
        Ok(id) => id,
        Err(reason) => {
            tracing::warn!(reason, "steam link: refused a sign-in response");
            return Ok(page(
                StatusCode::BAD_REQUEST,
                "Steam could not confirm this sign-in. Start again from slim-m.",
            ));
        }
    };
    let persona = steam.api().persona(&steam_id).await;
    let pending = PendingLink {
        user_id,
        username: persona
            .map(|p| p.chars().take(MAX_NAME_CHARS).collect())
            .unwrap_or_else(|| steam_id.clone()),
        external_id: steam_id,
        display_name: None,
        avatar_hash: None,
    };
    let handoff = state
        .store
        .create_link_handoff(STEAM, &pending, now_ms() + STATE_LIFETIME_MS)
        .await?;
    Ok(respond(
        StatusCode::OK,
        handoff_page(STEAM, "Steam", &handoff),
    ))
}

async fn unlink(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    state.store.unlink_account(ctx.user_id, STEAM).await?;
    super::steam_presence::clear_steam_activity(&state, ctx.user_id);
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct SharingBody {
    enabled: bool,
}

async fn set_sharing(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<SharingBody>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if !state
        .store
        .set_link_sharing(ctx.user_id, STEAM, body.enabled)
        .await?
    {
        return Err(ApiError::NotFound("link Steam first"));
    }
    if !body.enabled {
        super::steam_presence::clear_steam_activity(&state, ctx.user_id);
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_seventeen_digit_steam_openid_url_is_an_identity() {
        let ok = "https://steamcommunity.com/openid/id/76561198000000000";
        assert_eq!(steam_id_from_claimed(ok), Some("76561198000000000"));
        for bad in [
            "http://steamcommunity.com/openid/id/76561198000000000",
            "https://steamcommunity.com/openid/id/7656119800000000",
            "https://steamcommunity.com/openid/id/765611980000000000",
            "https://steamcommunity.com/openid/id/7656119800000000a",
            "https://steamcommunity.com.evil.example/openid/id/76561198000000000",
            "https://evil.example/https://steamcommunity.com/openid/id/76561198000000000",
            "https://steamcommunity.com/openid/id/76561198000000000/",
        ] {
            assert_eq!(steam_id_from_claimed(bad), None, "{bad}");
        }
    }
}
