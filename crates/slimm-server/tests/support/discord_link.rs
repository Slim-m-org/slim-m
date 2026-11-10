// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The browser and app halves of finishing a Discord link, for the suites that
//! drive it against a local fake of Discord.

use axum::Router;
use axum::body::Body;
use axum::http::Request;
use axum::response::Response;
use tower::ServiceExt;

/// A response body as text, for the pages a browser tab gets.
pub async fn text_body(response: Response) -> String {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}

/// The handoff code on the callback page, read off its "Open slim-m" link.
pub fn handoff_in(html: &str) -> String {
    let marker = "slimm://discord-link?code=";
    let from = html.find(marker).expect("the page links back to the app") + marker.len();
    html[from..]
        .chars()
        .take_while(char::is_ascii_alphanumeric)
        .collect()
}

/// `POST /me/links/discord/complete` as `token` with `code`.
pub async fn complete(app: &Router, token: &str, code: &str) -> Response {
    app.clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/me/links/discord/complete")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::json!({ "code": code }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap()
}
