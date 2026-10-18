// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /invite/{code}`: the page an https invite link opens.
//!
//! Chat apps linkify https and not `slimm://`, so the shareable form of an
//! invite is this page. It discloses exactly what `/invites/{code}/check`
//! does, and an unusable code answers one fixed page, so it cannot be used to
//! tell the four unusable states apart or to mine codes.

use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{Html, IntoResponse, Response};

use super::AppState;
use super::error::ApiError;
use super::extract::{INVITE_CHECK, RateLimited};
use super::invites::invite_code_key;
use crate::store::InviteCheck;

const RELEASES_URL: &str = "https://github.com/Slim-m-org/slim-m/releases/latest";

/// Inline script and style only, and nothing may frame or leak the code.
const CSP: &str = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; \
                   script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; \
                   form-action 'none'; frame-ancestors 'none'";

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

fn respond(status: StatusCode, html: String) -> Response {
    let mut response = (status, Html(html)).into_response();
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(CSP),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
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

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            b => format!("%{b:02X}"),
        })
        .collect()
}

const STYLE: &str = "\
:root{color-scheme:light dark;--bg:#f6f6f8;--card:#fff;--text:#16161a;--muted:#5d5d68;\
--line:#dcdce3;--accent:#4a5cf0;--on-accent:#fff}\
@media(prefers-color-scheme:dark){:root{--bg:#111114;--card:#1b1b20;--text:#f1f1f4;\
--muted:#a0a0ac;--line:#2e2e36;--accent:#7d8bff;--on-accent:#101018}}\
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;\
padding:16px;background:var(--bg);color:var(--text);\
font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}\
main{width:100%;max-width:400px;background:var(--card);border:1px solid var(--line);\
border-radius:16px;padding:32px 24px;text-align:center}\
.icon{width:72px;height:72px;border-radius:18px;object-fit:cover;margin:0 auto 16px;display:block}\
h1{font-size:22px;line-height:1.3;margin:0 0 4px}p{margin:0}.muted{color:var(--muted);font-size:14px}\
.actions{display:grid;gap:12px;margin-top:24px}\
a.btn{display:block;padding:12px 16px;border-radius:12px;border:1px solid var(--line);\
color:var(--text);text-decoration:none;font-weight:600}\
a.primary{background:var(--accent);border-color:var(--accent);color:var(--on-accent)}\
a.btn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}\
[hidden]{display:none!important}.foot{margin-top:20px}.foot a{color:var(--muted)}";

fn shell(title: &str, inner: &str, script: &str) -> String {
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
         <meta name=\"robots\" content=\"noindex\"><title>{title}</title>\
         <style>{STYLE}</style></head><body><main>{inner}</main>{script}</body></html>",
        title = escape(title),
    )
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

/// Reveals "Open in browser" only when this deployment serves the web client.
const WEB_PROBE: &str = "<script>fetch('/app/version.json',{cache:'no-store'})\
.then(function(r){return r.ok?r.json():null})\
.then(function(j){if(j&&typeof j.build==='string')document.getElementById('web').hidden=false})\
.catch(function(){})</script>";

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
