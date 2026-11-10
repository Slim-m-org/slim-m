// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /invite/{code}`: the page an https invite link opens.
//!
//! Chat apps linkify https and not `slimm://`, so the shareable form of an
//! invite is this page. It discloses exactly what `/invites/{code}/check`
//! does, and an unusable code answers one fixed page, so it cannot be used to
//! tell the four unusable states apart or to mine codes.

use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::http::{StatusCode, header};
use axum::response::Response;

use super::AppState;
use super::error::ApiError;
use super::extract::{INVITE_CHECK, RateLimited};
use super::invites::invite_code_key;
use super::page_shell::{WEB_PROBE, escape, percent_encode, respond, shell};
use crate::store::InviteCheck;

const RELEASES_URL: &str = "https://github.com/Slim-m-org/slim-m/releases/latest";

pub(super) struct Landing {
    pub space: String,
    pub member_count: i64,
    pub invited_by: Option<String>,
    pub has_icon: bool,
    pub code: String,
    pub origin: Option<String>,
}

pub(super) fn routes() -> axum::Router<AppState> {
    axum::Router::new().route("/invite/{code}", axum::routing::get(page))
}

async fn page(
    _limited: RateLimited<INVITE_CHECK>,
    Path(code): Path<String>,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let key = invite_code_key(&code);
    let body = match state.store.check_invite(&key).await? {
        InviteCheck::Unusable => return Ok(respond(StatusCode::NOT_FOUND, unusable_page())),
        InviteCheck::Usable(meta) => Landing {
            space: state.store.deployment_name().await?,
            member_count: state.store.member_count().await?,
            invited_by: meta.invited_by,
            has_icon: state.store.space_landing().await?.icon_updated_at.is_some(),
            code: key,
            origin: request_origin(&parts),
        },
    };
    Ok(respond(StatusCode::OK, landing_page(&body)))
}

/// The scheme and host the visitor used, or None when the Host header is not
/// a plain host[:port]. Only ever echoed back to the same visitor.
fn request_origin(parts: &Parts) -> Option<String> {
    let host = parts.headers.get(header::HOST)?.to_str().ok()?;
    let plain = !host.is_empty()
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':' | b'[' | b']'));
    if !plain {
        return None;
    }
    let scheme = match parts
        .headers
        .get("x-forwarded-proto")
        .and_then(|v| v.to_str().ok())
    {
        Some("https") => "https",
        _ => "http",
    };
    Some(format!("{scheme}://{host}"))
}

pub(super) fn unusable_page() -> String {
    shell(
        "Invite not available - slim-m",
        "<h1>This invite is not available</h1>\
         <p class=\"muted\">It may have expired or already been used. \
         Ask the person who sent it for a new one.</p>",
        "",
    )
}

pub(super) fn landing_page(landing: &Landing) -> String {
    let code = percent_encode(&landing.code);
    let icon = if landing.has_icon {
        format!(
            "<img class=\"icon\" alt=\"\" src=\"/invites/{code}/icon\" width=\"72\" height=\"72\">"
        )
    } else {
        String::new()
    };
    let invited_by = landing
        .invited_by
        .as_deref()
        .map(|name| format!("{} invited you to join", escape(name)))
        .unwrap_or_else(|| "You are invited to join".to_owned());
    let members = match landing.member_count {
        1 => "1 member".to_owned(),
        n => format!("{n} members"),
    };
    let (open_app, browser, script) = match &landing.origin {
        Some(origin) => {
            let server = percent_encode(origin);
            (
                format!(
                    "<a class=\"btn primary\" href=\"slimm://join?server={server}&amp;code={code}\">\
                     Open in slim-m</a>"
                ),
                format!(
                    "<a class=\"btn\" id=\"web\" hidden href=\"/app/join?server={server}&amp;code={code}\">\
                     Open in browser</a>"
                ),
                WEB_PROBE,
            )
        }
        None => (String::new(), String::new(), ""),
    };
    let inner = format!(
        "{icon}<p class=\"muted\">{invited_by}</p><h1>{space}</h1>\
         <p class=\"muted\">{members}</p>\
         <div class=\"actions\">{open_app}{browser}\
         <a class=\"btn\" href=\"{RELEASES_URL}\">Get the app</a></div>\
         <p class=\"muted foot\">Invite code <strong>{plain}</strong></p>",
        space = escape(&landing.space),
        plain = escape(&landing.code),
    );
    shell(&format!("Join {} - slim-m", landing.space), &inner, script)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn landing(space: &str) -> Landing {
        Landing {
            space: space.to_owned(),
            member_count: 3,
            invited_by: Some("Ada".to_owned()),
            has_icon: true,
            code: "abc234".to_owned(),
            origin: Some("https://chat.example".to_owned()),
        }
    }

    #[test]
    fn space_name_is_escaped() {
        let html = landing_page(&landing("<script>alert(1)</script>"));
        assert!(!html.contains("<script>alert(1)"));
        assert!(html.contains("&lt;script&gt;alert(1)"));
    }

    #[test]
    fn deep_link_carries_server_and_code() {
        let html = landing_page(&landing("Home"));
        assert!(html.contains("slimm://join?server=https%3A%2F%2Fchat.example&amp;code=abc234"));
        assert!(html.contains("/app/join?server=https%3A%2F%2Fchat.example"));
        assert!(html.contains("/invites/abc234/icon"));
    }

    #[test]
    fn no_origin_drops_app_links_but_keeps_download() {
        let mut model = landing("Home");
        model.origin = None;
        let html = landing_page(&model);
        assert!(!html.contains("slimm://"));
        assert!(!html.contains("fetch("));
        assert!(html.contains(RELEASES_URL));
    }
}
