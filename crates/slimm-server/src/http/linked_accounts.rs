// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Linking a Discord account to a member, through Discord's OAuth code flow.
//!
//! `/me/links/discord/start` mints a one-time state and hands back Discord's
//! authorize URL; the member's browser comes back to `/links/discord/callback`,
//! which spends the state, trades the code for a token, reads who that is and
//! stores the link. Only the `identify` scope is asked for, and the token is
//! dropped once the username is read.

use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::{Extension, Path, Query, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{delete, get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::messages::parse_uuid;
use crate::config::Config;
use crate::ids::UserId;
use crate::ratelimit::Class;
use crate::store::{AccountLinkError, LinkedAccount, now_ms};

const PROVIDER: &str = "discord";
const DISCORD_API: &str = "https://discord.com/api";
const STATE_LIFETIME_MS: i64 = 10 * 60 * 1000;
const DISCORD_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_NAME_CHARS: usize = 64;

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
    http: reqwest::Client,
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
        Ok(Some(Self::with_api(id, secret, redirect, DISCORD_API)?))
    }

    /// Points at another API host; tests use it for a local fake Discord.
    pub fn with_api(
        client_id: &str,
        client_secret: &str,
        redirect_uri: &str,
        api_base: &str,
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
                http,
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
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/me/links", get(list_mine))
        .route("/me/links/discord/start", post(start))
        .route("/me/links/discord", delete(unlink))
        .route("/links/discord/callback", get(callback))
        .route("/users/{user_id}/links", get(list_for_user))
}

#[derive(Serialize)]
struct LinkedAccountDto {
    provider: String,
    username: String,
    display_name: Option<String>,
    linked_at: i64,
}

impl From<LinkedAccount> for LinkedAccountDto {
    fn from(account: LinkedAccount) -> Self {
        Self {
            provider: account.provider,
            username: account.username,
            display_name: account.display_name,
            linked_at: account.linked_at,
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
            PROVIDER,
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

/// What the browser tab shows. Fixed text only: nothing from the request
/// is echoed into the page.
fn page(status: StatusCode, message: &str) -> Response {
    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" \
         content=\"width=device-width\"><title>slim-m</title></head><body style=\"\
         font-family:system-ui,sans-serif;display:grid;place-items:center;height:90vh;\
         margin:0\"><p>{message}</p></body></html>"
    );
    (status, Html(body)).into_response()
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
    let Some(user_id) = state.store.take_link_state(&link_state, PROVIDER).await? else {
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
    let account = LinkedAccount {
        provider: PROVIDER.to_owned(),
        external_id: user.id.chars().take(MAX_NAME_CHARS).collect(),
        username: user.username.chars().take(MAX_NAME_CHARS).collect(),
        display_name: user
            .global_name
            .map(|name| name.chars().take(MAX_NAME_CHARS).collect()),
        linked_at: now_ms(),
    };
    match state.store.save_linked_account(user_id, &account).await {
        Ok(()) => Ok(page(
            StatusCode::OK,
            "Discord is linked. You can close this tab.",
        )),
        Err(AccountLinkError::TakenByAnotherMember) => Ok(page(
            StatusCode::CONFLICT,
            "That Discord account is already linked to someone else here.",
        )),
        Err(AccountLinkError::Internal(error)) => Err(error.into()),
    }
}

async fn unlink(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    state.store.unlink_account(ctx.user_id, PROVIDER).await?;
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
