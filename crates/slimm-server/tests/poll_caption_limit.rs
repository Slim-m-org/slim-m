// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A poll's caption is bounded by the same rule as any message's text, so its
//! refusal names how far over the limit it is instead of a bare "too long".

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

#[tokio::test]
async fn an_over_long_poll_caption_names_how_far_over_it_is() {
    let (path, _guard) = support::TestDbGuard::new("slimm-poll-caption");
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
    let app = http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });

    let body = json!({
        "id": Uuid::now_v7().to_string(),
        "content": "x".repeat(4001),
        "question": "tabs or spaces?",
        "options": ["tabs", "spaces"],
    });
    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/channels/{}/messages/polls", channel.id))
                .header("authorization", format!("Bearer {}", token.access_token))
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let error = serde_json::from_slice::<Value>(&bytes).unwrap()["error"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(error.contains("1 characters over"), "{error}");
}
