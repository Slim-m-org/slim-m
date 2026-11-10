// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Finishing a Discord link from the app of the member who started it.
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
use super::linked_accounts::{DiscordLinks, LinkedAccountDto, PROVIDER, store_avatar};
use super::page_shell::{WEB_PROBE, percent_encode, shell};
use crate::ratelimit::Class;
use crate::store::{AccountLinkError, LinkedAccount, now_ms};

/// A code that is wrong, expired, spent or another member's all read the same.
const REFUSED: &str = "that link code is not valid, or it has expired";
const MAX_CODE_CHARS: usize = 64;

pub(super) fn routes() -> Router<AppState> {
    Router::new().route("/me/links/discord/complete", post(complete))
}

#[derive(Deserialize)]
struct CompleteBody {
    code: String,
}

async fn complete(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    discord: Option<Extension<DiscordLinks>>,
    Json(body): Json<CompleteBody>,
) -> Result<Json<LinkedAccountDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if body.code.chars().count() > MAX_CODE_CHARS {
        return Err(ApiError::NotFound(REFUSED));
    }
    let pending = state
        .store
        .take_link_handoff(&body.code, PROVIDER)
        .await?
        .filter(|pending| pending.user_id == ctx.user_id)
        .ok_or(ApiError::NotFound(REFUSED))?;
    let avatar = match (discord, pending.avatar_hash.as_deref()) {
        (Some(Extension(discord)), Some(hash)) => {
            discord.fetch_avatar(&pending.external_id, hash).await
        }
        _ => None,
    };
    let now = now_ms();
    let account = LinkedAccount {
        provider: PROVIDER.to_owned(),
        external_id: pending.external_id,
        username: pending.username,
        display_name: pending.display_name,
        linked_at: now,
        avatar_updated_at: avatar.as_ref().map(|_| now),
    };
    match state.store.save_linked_account(ctx.user_id, &account).await {
        Ok(()) => {
            store_avatar(&state, ctx.user_id, avatar).await;
            Ok(Json(account.into()))
        }
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

/// What the browser shows once Discord has approved: the way back into the app.
pub(super) fn handoff_page(code: &str) -> String {
    let code_param = percent_encode(code);
    let inner = format!(
        "<h1>Finish in slim-m</h1>\
         <p class=\"muted\">Discord approved. Open slim-m on the account that started the link.</p>\
         <div class=\"actions\">\
         <a class=\"btn primary\" href=\"slimm://discord-link?code={code_param}\">Open slim-m</a>\
         <a class=\"btn\" id=\"web\" hidden href=\"/app/link/discord?code={code_param}\">Open in browser</a>\
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
        let html = handoff_page("ABCDEFGHJKLMNPQRSTUVWXYZ2");
        assert!(html.contains("slimm://discord-link?code=ABCDEFGHJKLMNPQRSTUVWXYZ2"));
        assert!(html.contains("/app/link/discord?code=ABCDEFGHJKLMNPQRSTUVWXYZ2"));
        assert!(html.contains("ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2"));
    }

    #[test]
    fn grouping_a_short_tail_keeps_every_character() {
        assert_eq!(grouped("ABCDEFG"), "ABCDE-FG");
    }
}
