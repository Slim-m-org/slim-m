// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A message made only of characters that draw nothing is empty, the same
//! rule names follow, and control and text-direction override characters are
//! stripped from what is stored, on a send and on an edit alike.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{json_body, register_token_id as register, request};

async fn general() -> (Router, String, String, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-msg-hidden-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = support::app::builder(store.clone())
        .auth(Auth::new(2).expect("auth service"))
        .router();
    let (token, _user) = register(&store, "alice").await;
    (
        app,
        token,
        format!("/channels/{}/messages", channel.id),
        guard,
    )
}

async fn send(app: &Router, token: &str, uri: &str, content: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            uri,
            Some(token),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
        ))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body(response).await)
}

#[tokio::test]
async fn a_message_of_only_invisible_characters_is_empty() {
    let (app, token, uri, _guard) = general().await;
    for blank in [
        "\u{200B}",
        "\u{200D}\u{200D}",
        "\u{2800}",
        "\u{3164}",
        "\u{FE0F}",
        " \u{200B}\n\u{2060} ",
        "\u{0}\u{7}\u{1B}",
        "\u{202E}",
    ] {
        let (status, body) = send(&app, &token, &uri, blank).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{blank:?}");
        assert_eq!(
            body["error"], "message content must not be empty",
            "{blank:?}"
        );
    }
}

#[tokio::test]
async fn controls_and_direction_overrides_are_stripped_and_text_kept() {
    let (app, token, uri, _guard) = general().await;
    let cases = [
        ("bell\u{7} and nul\u{0} gone", "bell and nul gone"),
        ("esc\u{1B}[31m red", "esc[31m red"),
        ("invoice\u{202E}fdp.exe", "invoicefdp.exe"),
        ("a\u{2066}b\u{2069}c", "abc"),
        ("line one\r\nline two\tend", "line one\nline two\tend"),
        (
            "family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
            "family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        ),
        ("heart \u{2764}\u{FE0F}", "heart \u{2764}\u{FE0F}"),
    ];
    for (sent, stored) in cases {
        let (status, body) = send(&app, &token, &uri, sent).await;
        assert_eq!(status, StatusCode::OK, "{sent:?}: {body}");
        assert_eq!(body["content"], stored, "{sent:?}");
    }
}

#[tokio::test]
async fn an_edit_is_held_to_the_same_rule() {
    let (app, token, uri, _guard) = general().await;
    let (_, sent) = send(&app, &token, &uri, "original").await;
    let edit_uri = format!("{uri}/{}", sent["id"].as_str().unwrap());
    let edit = |content: &'static str| {
        let app = app.clone();
        let token = token.clone();
        let edit_uri = edit_uri.clone();
        async move {
            let response = app
                .oneshot(request(
                    "PATCH",
                    &edit_uri,
                    Some(&token),
                    Some(json!({ "content": content })),
                ))
                .await
                .unwrap();
            let status = response.status();
            (status, json_body(response).await)
        }
    };
    let (status, _) = edit("\u{200B}\u{2800}").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, body) = edit("fixed\u{7}").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["content"], "fixed");
}
