// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The small self-contained HTML pages a browser tab gets from the server: one
//! card on a plain background, light or dark, with no external requests.

use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{Html, IntoResponse, Response};

/// Inline script and style only, and nothing may frame or leak the code.
const CSP: &str = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; \
                   script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; \
                   form-action 'none'; frame-ancestors 'none'";

/// Answers `html` under the page headers: the policy above, no referrer and no caching.
pub(super) fn respond(status: StatusCode, html: String) -> Response {
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

pub(super) fn escape(text: &str) -> String {
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

pub(super) fn percent_encode(text: &str) -> String {
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
button.btn{width:100%;padding:12px 16px;border-radius:12px;border:1px solid var(--line);\
background:transparent;color:var(--text);font:inherit;font-weight:600;cursor:pointer}\
a.btn:focus-visible,button.btn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}\
.code{margin:12px 0;padding:12px 16px;border:1px solid var(--line);border-radius:12px;\
font:600 18px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.04em;\
overflow-wrap:anywhere;user-select:all}\
[hidden]{display:none!important}.foot{margin-top:20px}.foot a{color:var(--muted)}";

pub(super) fn shell(title: &str, inner: &str, script: &str) -> String {
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
         <meta name=\"robots\" content=\"noindex\"><title>{title}</title>\
         <style>{STYLE}</style></head><body><main>{inner}</main>{script}</body></html>",
        title = escape(title),
    )
}

/// Reveals "Open in browser" only when this deployment serves the web client.
pub(super) const WEB_PROBE: &str = "<script>fetch('/app/version.json',{cache:'no-store'})\
.then(function(r){return r.ok?r.json():null})\
.then(function(j){if(j&&typeof j.build==='string')document.getElementById('web').hidden=false})\
.catch(function(){})</script>";
