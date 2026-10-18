// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Poll text accepts emoji sequences that need a joiner or tag characters, and
//! still refuses the same characters when they hide rather than join.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

async fn post_poll(question: &str, options: &[&str]) -> StatusCode {
    let (path, _guard) = support::TestDbGuard::new("slimm-poll-emoji");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let account = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store.open_session(account.id, "cli").await.unwrap();
    let app = support::app::router(store);
    let body = json!({
        "id": Uuid::now_v7().to_string(),
        "question": question,
        "options": options,
    });
    app.oneshot(
        Request::builder()
            .method("POST")
            .uri(format!("/channels/{}/messages/polls", channel.id))
            .header("authorization", format!("Bearer {}", token.access_token))
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap(),
    )
    .await
    .unwrap()
    .status()
}

const FAMILY: &str = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
const SCOTLAND: &str = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}";

#[tokio::test]
async fn zwj_and_subdivision_flag_emoji_are_accepted_in_poll_text() {
    let question = format!("who is in the {FAMILY}?");
    let status = post_poll(&question, &[FAMILY, SCOTLAND]).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_bare_joiner_or_lone_tag_character_is_still_refused() {
    for bad in [
        "a\u{200D}b",
        "\u{200D}",
        "\u{1F468}\u{200D}",
        "\u{200D}\u{1F469}",
        "\u{1F468}\u{200D}\u{200D}\u{1F469}",
        "a\u{E0067}",
        "\u{E0067}",
        "\u{1F3F4}\u{E0067}",
        "\u{1F3F4}\u{E007F}",
        "\u{1F3F4}\u{E0067}\u{E007F}\u{E0067}",
    ] {
        let as_question = post_poll(bad, &["a", "b"]).await;
        assert_eq!(as_question, StatusCode::BAD_REQUEST, "question {bad:?}");
        let as_option = post_poll("q", &[bad, "b"]).await;
        assert_eq!(as_option, StatusCode::BAD_REQUEST, "option {bad:?}");
    }
}
