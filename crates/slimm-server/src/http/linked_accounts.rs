// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Linking a Discord account to a member, through Discord's OAuth code flow.
//! The list routes and the handoff are shared with Steam (`steam_link`).
//!
//! `/me/links/discord/start` mints a one-time state and hands back Discord's
//! authorize URL; the browser comes back to `/links/discord/callback`, which
//! spends the state, trades the code for a token and reads who that is. It
//! links nothing, because it cannot tell who approved: it holds the identity
//! for the member's own app to finish (see `link_handoff`). Only the
//! `identify` scope is asked for, and the token is dropped once the username
//! is read.

use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::{Extension, Path, Query, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::Response;
use axum::routing::{delete, get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::link_handoff::{self, handoff_page};
use super::linked_avatar;
use super::messages::parse_uuid;
use super::page_shell::{escape, respond, shell};
use crate::config::Config;
use crate::ids::UserId;
use crate::ratelimit::Class;
use crate::store::{LinkedAccount, PendingLink, now_ms};

pub(super) const DISCORD: &str = "discord";
pub(super) const STEAM: &str = "steam";
const DISCORD_API: &str = "https://discord.com/api";
const DISCORD_CDN: &str = "https://cdn.discordapp.com";
pub(super) const STATE_LIFETIME_MS: i64 = 10 * 60 * 1000;
const DISCORD_TIMEOUT: Duration = Duration::from_secs(10);
pub(super) const MAX_NAME_CHARS: usize = 64;

/// The configured Discord application, or nothing when linking is off.
/// Handed to the router as an `Extension` so the many test `AppState`s need
/// no new field; a router without it answers "not configured".
#[derive(Clone)]
pub struct DiscordLinks {
    inner: Arc<DiscordApp>,
}

struct DiscordApp {
    client_id: String,
    client_secret: String,
    redirect_uri: String,
    api_base: String,
    cdn_base: String,
    http: reqwest::Client,
    avatar_http: reqwest::Client,
}

impl DiscordLinks {
    /// `None` unless the client id, secret and redirect URI are all set.
    pub fn new(config: &Config) -> anyhow::Result<Option<Self>> {
        let (Some(id), Some(secret), Some(redirect)) = (
            config.discord_client_id.as_deref(),
            config.discord_client_secret.as_deref(),
            config.discord_redirect_uri.as_deref(),
        ) else {
            return Ok(None);
        };
        Ok(Some(Self::build(
            (id, secret, redirect),
            (DISCORD_API, DISCORD_CDN),
            false,
        )?))
    }

    /// Points the API and the picture CDN at one local fake Discord, which
    /// the picture fetch may then reach on loopback; tests use it.
    pub fn with_api(
        client_id: &str,
        client_secret: &str,
        redirect_uri: &str,
        api_base: &str,
    ) -> anyhow::Result<Self> {
        Self::build(
            (client_id, client_secret, redirect_uri),
            (api_base, api_base),
            true,
        )
    }

    fn build(
        (client_id, client_secret, redirect_uri): (&str, &str, &str),
        (api_base, cdn_base): (&str, &str),
        allow_private: bool,
    ) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(DISCORD_TIMEOUT)
            .build()?;
        Ok(Self {
            inner: Arc::new(DiscordApp {
                client_id: client_id.to_owned(),
                client_secret: client_secret.to_owned(),
                redirect_uri: redirect_uri.to_owned(),
                api_base: api_base.trim_end_matches('/').to_owned(),
                cdn_base: cdn_base.trim_end_matches('/').to_owned(),
                http,
                avatar_http: linked_avatar::build_client(allow_private),
            }),
        })
    }

    fn authorize_url(&self, state: &str) -> String {
        let app = &self.inner;
        let mut url =
            url::Url::parse("https://discord.com/oauth2/authorize").expect("a constant URL parses");
        url.query_pairs_mut()
            .append_pair("response_type", "code")
            .append_pair("client_id", &app.client_id)
            .append_pair("scope", "identify")
            .append_pair("redirect_uri", &app.redirect_uri)
            .append_pair("state", state)
            .append_pair("prompt", "none");
        url.into()
    }

    async fn identify(&self, code: &str) -> anyhow::Result<DiscordUser> {
        let app = &self.inner;
        let token: TokenResponse = app
            .http
            .post(format!("{}/oauth2/token", app.api_base))
            .form(&[
                ("client_id", app.client_id.as_str()),
                ("client_secret", app.client_secret.as_str()),
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", app.redirect_uri.as_str()),
            ])
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let user = app
            .http
            .get(format!("{}/users/@me", app.api_base))
            .bearer_auth(&token.access_token)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(user)
    }

    /// The account's custom picture, or `None` for any failure fetching it.
    pub(super) async fn fetch_avatar(&self, discord_id: &str, hash: &str) -> Option<Vec<u8>> {
        if !linked_avatar::is_path_safe(discord_id, hash) {
            return None;
        }
        let url = format!(
            "{}/avatars/{discord_id}/{hash}.png?size=128",
            self.inner.cdn_base
        );
        linked_avatar::fetch(&self.inner.avatar_http, &url).await
    }
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
}

#[derive(Deserialize)]
struct DiscordUser {
    id: String,
    username: String,
    global_name: Option<String>,
    avatar: Option<String>,
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/me/links", get(list_mine))
        .route("/me/links/discord/start", post(start))
        .route("/me/links/discord", delete(unlink))
        .route("/links/discord/callback", get(callback))
        .route("/users/{user_id}/links", get(list_for_user))
        .route(
            "/users/{user_id}/links/discord/avatar",
            get(linked_avatar::get_discord_avatar),
        )
        .merge(link_handoff::routes())
        .merge(super::steam_link::routes())
}

#[derive(Serialize)]
pub(super) struct LinkedAccountDto {
    provider: String,
    username: String,
    display_name: Option<String>,
    linked_at: i64,
    avatar_updated_at: Option<i64>,
    share_activity: bool,
}

impl From<LinkedAccount> for LinkedAccountDto {
    fn from(account: LinkedAccount) -> Self {
        Self {
            provider: account.provider,
            username: account.username,
            display_name: account.display_name,
            linked_at: account.linked_at,
            avatar_updated_at: account.avatar_updated_at,
            share_activity: account.share_activity,
        }
    }
}

#[derive(Serialize)]
struct StartDto {
    url: String,
}

async fn start(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    discord: Option<Extension<DiscordLinks>>,
) -> Result<Json<StartDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let Some(Extension(discord)) = discord else {
        return Err(ApiError::NotConfigured(
            "Discord linking is not set up on this server",
        ));
    };
    let link_state = crate::auth::generate_secret();
    state
        .store
        .create_link_state(
            ctx.user_id,
            DISCORD,
            &link_state,
            now_ms() + STATE_LIFETIME_MS,
        )
        .await?;
    Ok(Json(StartDto {
        url: discord.authorize_url(&link_state),
    }))
}

#[derive(Deserialize)]
struct CallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

/// What the browser tab shows when there is nothing to hand back. Fixed text
/// only: nothing from the request is echoed into the page.
pub(super) fn page(status: StatusCode, message: &str) -> Response {
    let inner = format!("<p>{}</p>", escape(message));
    respond(status, shell("slim-m", &inner, ""))
}

async fn callback(
    State(state): State<AppState>,
    parts: Parts,
    discord: Option<Extension<DiscordLinks>>,
    Query(query): Query<CallbackQuery>,
) -> Result<Response, ApiError> {
    enforce(&state, &parts, None, Class::InviteCheck)?;
    let Some(Extension(discord)) = discord else {
        return Ok(page(
            StatusCode::NOT_IMPLEMENTED,
            "Discord linking is not set up on this server.",
        ));
    };
    let Some(link_state) = query.state.filter(|s| s.len() <= 128) else {
        return Ok(page(
            StatusCode::BAD_REQUEST,
            "This link is not valid. Start again from slim-m.",
        ));
    };
    let Some(user_id) = state.store.take_link_state(&link_state, DISCORD).await? else {
        return Ok(page(
            StatusCode::BAD_REQUEST,
            "This link has expired or was already used. Start again from slim-m.",
        ));
    };
    if query.error.is_some() {
        return Ok(page(
            StatusCode::OK,
            "Linking was cancelled. You can close this tab.",
        ));
    }
    let Some(code) = query.code.filter(|c| !c.is_empty() && c.len() <= 256) else {
        return Ok(page(
            StatusCode::BAD_REQUEST,
            "Discord sent no code. Start again from slim-m.",
        ));
    };
    let user = match discord.identify(&code).await {
        Ok(user) => user,
        Err(error) => {
            tracing::warn!(%error, "discord link: could not read the account");
            return Ok(page(
                StatusCode::BAD_GATEWAY,
                "Discord did not answer. Try again in a moment.",
            ));
        }
    };
    let pending = PendingLink {
        user_id,
        external_id: user.id.chars().take(MAX_NAME_CHARS).collect(),
        username: user.username.chars().take(MAX_NAME_CHARS).collect(),
        display_name: user
            .global_name
            .map(|name| name.chars().take(MAX_NAME_CHARS).collect()),
        avatar_hash: user
            .avatar
            .filter(|hash| linked_avatar::is_path_safe(&user.id, hash)),
    };
    let handoff = state
        .store
        .create_link_handoff(DISCORD, &pending, now_ms() + STATE_LIFETIME_MS)
        .await?;
    Ok(respond(
        StatusCode::OK,
        handoff_page(DISCORD, "Discord", &handoff),
    ))
}

/// Writes the fetched picture, or removes an earlier link's when this one has
/// none. A file that cannot be written leaves the link without a picture.
pub(super) async fn store_avatar(state: &AppState, user_id: UserId, avatar: Option<Vec<u8>>) {
    let owner = user_id.to_string();
    let written = match avatar {
        Some(bytes) => {
            state
                .media
                .write_linked_avatar(DISCORD, &owner, bytes)
                .await
        }
        None => state.media.delete_linked_avatar(DISCORD, &owner).await,
    };
    if let Err(error) = written {
        tracing::warn!(%error, "discord link: could not store the picture");
        if let Err(error) = state.store.clear_linked_avatar(user_id, DISCORD).await {
            tracing::warn!(%error, "discord link: could not clear the picture marker");
        }
    }
}

/// Removes every picture file a member's links stored.
pub(super) async fn purge_avatar_files(state: &AppState, user_id: UserId) {
    if let Err(error) = state
        .media
        .delete_linked_avatar(DISCORD, &user_id.to_string())
        .await
    {
        tracing::warn!(%error, "failed to delete a linked account's picture file");
    }
}

async fn unlink(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    state.store.unlink_account(ctx.user_id, DISCORD).await?;
    purge_avatar_files(&state, ctx.user_id).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn list_mine(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<Vec<LinkedAccountDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let accounts = state.store.linked_accounts(ctx.user_id).await?;
    Ok(Json(accounts.into_iter().map(Into::into).collect()))
}

async fn list_for_user(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(user_id): Path<String>,
) -> Result<Json<Vec<LinkedAccountDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let user_id = UserId(parse_uuid(&user_id)?);
    let accounts = state.store.linked_accounts(user_id).await?;
    Ok(Json(accounts.into_iter().map(Into::into).collect()))
}
