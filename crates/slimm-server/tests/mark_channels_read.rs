// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /read-states/read`: one request clears a category or a whole space.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-mark-channels-read");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn state_for(store: &Store) -> AppState {
    AppState {
        store: store.clone(),
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
    }
}

async fn token_for(store: &Store, name: &str) -> (UserId, String) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    (user.id, tokens.access_token)
}

async fn post_message(store: &Store, channel: ChannelId, author: UserId) {
    store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap();
}

async fn mark(state: &AppState, token: &str, channels: &[ChannelId]) -> (StatusCode, Value) {
    let ids: Vec<String> = channels.iter().map(ToString::to_string).collect();
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/read-states/read")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "channel_ids": ids }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

#[tokio::test]
async fn one_request_reads_every_listed_channel_to_its_latest_message() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let first = store.create_channel("one", "text").await.unwrap();
    let second = store.create_channel("two", "text").await.unwrap();
    let (author, _) = token_for(&store, "bob").await;
    let (reader, token) = token_for(&store, "alice").await;
    for channel in [first.id, second.id] {
        post_message(&store, channel, author).await;
        post_message(&store, channel, author).await;
    }
    store.mark_unread(reader, first.id).await.unwrap();

    let state = state_for(&store);
    let (status, body) = mark(&state, &token, &[first.id, second.id]).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body.as_array().unwrap().len(), 2);
    for channel in [first.id, second.id] {
        assert_eq!(store.unread_count(reader, channel).await.unwrap(), 0);
        assert_eq!(store.last_read_seq(reader, channel).await.unwrap(), 2);
    }
    assert!(!store.manually_unread(reader, first.id).await.unwrap());
}

#[tokio::test]
async fn a_channel_the_caller_cannot_view_is_skipped_and_left_alone() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let open = store.create_channel("open", "text").await.unwrap();
    let hidden = store.create_channel("hidden", "text").await.unwrap();
    let (author, _) = token_for(&store, "bob").await;
    let (reader, token) = token_for(&store, "alice").await;
    store
        .set_member_overwrite(
            hidden.id,
            reader,
            Permissions::from_bits(0),
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    post_message(&store, open.id, author).await;
    post_message(&store, hidden.id, author).await;

    let state = state_for(&store);
    let (status, body) = mark(&state, &token, &[open.id, hidden.id]).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body.as_array().unwrap().len(), 1);
    assert_eq!(store.unread_count(reader, open.id).await.unwrap(), 0);
    assert_eq!(store.last_read_seq(reader, hidden.id).await.unwrap(), 0);
}

#[tokio::test]
async fn more_channels_than_the_cap_is_refused() {
    let (store, _guard) = new_store().await;
    let (_, token) = token_for(&store, "alice").await;
    let ids: Vec<ChannelId> = (0..201).map(|_| ChannelId::generate()).collect();

    let state = state_for(&store);
    let (status, _) = mark(&state, &token, &ids).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
}
