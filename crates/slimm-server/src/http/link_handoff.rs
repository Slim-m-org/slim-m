// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Finishing a Discord or Steam link from the app of the member who started it.
//! The callback's browser has no session, so it only holds the identity under a
//! handoff code; the app links it with its own bearer, and only for the starter.

use axum::extract::State;
use axum::http::request::Parts;
use axum::routing::post;
use axum::{Extension, Router};
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::linked_accounts::{DISCORD, DiscordLinks, LinkedAccountDto, STEAM, store_avatar};
use super::page_shell::{WEB_PROBE, percent_encode, shell};
use crate::ids::UserId;
use crate::ratelimit::Class;
use crate::store::{AccountLinkError, LinkedAccount, PendingLink, now_ms};

/// A code that is wrong, expired, spent or another member's all read the same.
const REFUSED: &str = "that link code is not valid, or it has expired";
const MAX_CODE_CHARS: usize = 64;

pub(super) fn routes() -> Router<AppState> {
    Router::new()
        .route("/me/links/discord/complete", post(complete_discord))
        .route("/me/links/steam/complete", post(complete_steam))
}

#[derive(Deserialize)]
struct CompleteBody {
    code: String,
}

async fn complete_discord(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    discord: Option<Extension<DiscordLinks>>,
    Json(body): Json<CompleteBody>,
) -> Result<Json<LinkedAccountDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let pending = take_pending(&state, ctx.user_id, DISCORD, &body.code).await?;
    let avatar = match (discord, pending.avatar_hash.as_deref()) {
        (Some(Extension(discord)), Some(hash)) => {
            discord.fetch_avatar(&pending.external_id, hash).await
        }
        _ => None,
    };
    let account = account_from(DISCORD, pending, avatar.is_some());
    save(&state, ctx.user_id, &account).await?;
    store_avatar(&state, ctx.user_id, avatar).await;
    Ok(Json(account.into()))
}

async fn complete_steam(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<CompleteBody>,
) -> Result<Json<LinkedAccountDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let pending = take_pending(&state, ctx.user_id, STEAM, &body.code).await?;
    let account = account_from(STEAM, pending, false);
    save(&state, ctx.user_id, &account).await?;
    Ok(Json(account.into()))
}

async fn take_pending(
    state: &AppState,
    user_id: UserId,
    provider: &str,
    code: &str,
) -> Result<PendingLink, ApiError> {
    if code.chars().count() > MAX_CODE_CHARS {
        return Err(ApiError::NotFound(REFUSED));
    }
    state
        .store
        .take_link_handoff(code, provider)
        .await?
        .filter(|pending| pending.user_id == user_id)
        .ok_or(ApiError::NotFound(REFUSED))
}

fn account_from(provider: &str, pending: PendingLink, has_avatar: bool) -> LinkedAccount {
    let now = now_ms();
    LinkedAccount {
        provider: provider.to_owned(),
        external_id: pending.external_id,
        username: pending.username,
        display_name: pending.display_name,
        linked_at: now,
        avatar_updated_at: has_avatar.then_some(now),
        share_activity: false,
    }
}

async fn save(state: &AppState, user_id: UserId, account: &LinkedAccount) -> Result<(), ApiError> {
    match state.store.save_linked_account(user_id, account).await {
        Ok(()) => Ok(()),
        Err(AccountLinkError::TakenByAnotherMember) if account.provider == STEAM => Err(
            ApiError::Conflict("that Steam account is already linked to someone else here"),
        ),
        Err(AccountLinkError::TakenByAnotherMember) => Err(ApiError::Conflict(
            "that Discord account is already linked to someone else here",
        )),
        Err(AccountLinkError::Internal(error)) => Err(error.into()),
    }
}

/// The code in groups of five, which is how a person reads one off a screen.
fn grouped(code: &str) -> String {
    code.as_bytes()
        .chunks(5)
        .map(|chunk| String::from_utf8_lossy(chunk))
        .collect::<Vec<_>>()
        .join("-")
}

const COPY_SCRIPT: &str = "<script>(function(){var b=document.getElementById('copy');\
if(!b||!navigator.clipboard)return;b.hidden=false;b.onclick=function(){\
navigator.clipboard.writeText(document.getElementById('code').textContent)\
.then(function(){b.textContent='Copied'}).catch(function(){})}})()</script>";

/// What the browser shows once the provider has approved: the way back into
/// the app. `provider` is the lowercase wire name, `label` the display one.
pub(super) fn handoff_page(provider: &str, label: &str, code: &str) -> String {
    let code_param = percent_encode(code);
    let inner = format!(
        "<h1>Finish in slim-m</h1>\
         <p class=\"muted\">{label} approved. Open slim-m on the account that started the link.</p>\
         <div class=\"actions\">\
         <a class=\"btn primary\" href=\"slimm://{provider}-link?code={code_param}\">Open slim-m</a>\
         <a class=\"btn\" id=\"web\" hidden href=\"/app/link/{provider}?code={code_param}\">Open in browser</a>\
         </div>\
         <p class=\"muted foot\">Or paste this code in Settings, Connections.</p>\
         <p class=\"code\" id=\"code\">{grouped}</p>\
         <button class=\"btn\" id=\"copy\" type=\"button\" hidden>Copy code</button>\
         <p class=\"muted foot\">It works once, for ten minutes.</p>",
        grouped = grouped(code),
    );
    shell(
        "Finish linking - slim-m",
        &inner,
        &format!("{WEB_PROBE}{COPY_SCRIPT}"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_page_carries_the_code_three_ways() {
        let html = handoff_page("discord", "Discord", "ABCDEFGHJKLMNPQRSTUVWXYZ2");
        assert!(html.contains("slimm://discord-link?code=ABCDEFGHJKLMNPQRSTUVWXYZ2"));
        assert!(html.contains("/app/link/discord?code=ABCDEFGHJKLMNPQRSTUVWXYZ2"));
        assert!(html.contains("ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2"));
    }

    #[test]
    fn the_steam_page_points_at_the_steam_link() {
        let html = handoff_page("steam", "Steam", "ABCDEFGHJKLMNPQRSTUVWXYZ2");
        assert!(html.contains("slimm://steam-link?code="));
        assert!(html.contains("Steam approved."));
    }

    #[test]
    fn grouping_a_short_tail_keeps_every_character() {
        assert_eq!(grouped("ABCDEFG"), "ABCDE-FG");
    }
}
