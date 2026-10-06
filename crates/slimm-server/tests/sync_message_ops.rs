// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message-op half of `POST /sync`, over the real route.
//!
//! The load-bearing one here is `an_old_client_is_never_told_to_reset`: a
//! client that sends no op cursor must never be given a reset it did not need,
//! because a reset wipes the whole channel's cache. Evaluating the op gap
//! unconditionally would do exactly that to every client in existence on the
//! first connect after deploy, and it is the sort of mistake that looks like a
//! simplification.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

async fn world() -> (Store, axum::Router, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    let app = http::router(AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    (store, app, guard)
}

async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

async fn sync(app: &axum::Router, token: &str, scopes: Value) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::post("/sync")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "scopes": scopes }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 22)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn send(store: &Store, channel: ChannelId, author: UserId, body: &str) -> MessageId {
    store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            body,
        ))
        .await
        .unwrap()
        .message
        .id
}

/// The mutation this exists for: evaluating the op gap unconditionally would
/// wipe every old client's cache on the first connect after deploy.
#[tokio::test]
async fn an_old_client_sending_no_op_cursor_gets_no_ops_and_no_reset() {
    let (store, app, _guard) = world().await;
    let (token, user) = register(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    let id = send(&store, channel, user, "hello").await;
    for i in 0..40 {
        store
            .edit_message(id, &format!("revision {i}"), user)
            .await
            .unwrap();
    }

    let (status, body) = sync(
        &app,
        &token,
        json!([{ "channel_id": channel.to_string(), "after_seq": 0 }]),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let scope = &body["scopes"][0];
    assert_eq!(scope["ops"].as_array().unwrap().len(), 0);
    assert_eq!(scope["ops_has_more"], false);
    assert_eq!(
        scope["reset"], false,
        "a client that cannot hold an op cursor must never be reset for lacking one"
    );
    assert_eq!(
        scope["op_latest_seq"], 40,
        "the head is still reported, so a client can adopt it"
    );
}

#[tokio::test]
async fn a_client_with_an_op_cursor_receives_the_ops_after_it() {
    let (store, app, _guard) = world().await;
    let (token, user) = register(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    let a = send(&store, channel, user, "one").await;
    let b = send(&store, channel, user, "two").await;
    store.edit_message(a, "one, revised", user).await.unwrap();
    store.delete_message(b, user).await.unwrap();

    let (status, body) = sync(
        &app,
        &token,
        json!([{ "channel_id": channel.to_string(), "after_seq": 99, "after_op_seq": 0 }]),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let ops = body["scopes"][0]["ops"].as_array().unwrap();
    assert_eq!(ops.len(), 2);
    assert_eq!(ops[0]["kind"], "edit");
    assert_eq!(ops[0]["seq"], 1);
    assert_eq!(ops[0]["content"], "one, revised");
    assert_eq!(ops[1]["kind"], "delete");
    assert_eq!(ops[1]["seq"], 2);
    assert_eq!(body["scopes"][0]["op_latest_seq"], 2);
}

/// The moderator's identity is on the op row and must not be on the wire.
///
/// Asserted against the serialised keys rather than a struct, so it fails for
/// a field added anywhere in the chain rather than only in the DTO.
#[tokio::test]
async fn no_op_carries_an_actor_on_any_kind() {
    let (store, app, _guard) = world().await;
    let (token, user) = register(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    let a = send(&store, channel, user, "one").await;
    let b = send(&store, channel, user, "two").await;
    store.edit_message(a, "revised", user).await.unwrap();
    store.delete_message(b, user).await.unwrap();

    let (_, body) = sync(
        &app,
        &token,
        json!([{ "channel_id": channel.to_string(), "after_seq": 99, "after_op_seq": 0 }]),
    )
    .await;
    let ops = body["scopes"][0]["ops"].as_array().unwrap();
    // A filter regression returning none would leave the loop asserting nothing.
    assert_eq!(ops.len(), 2, "expected the edit and the delete: {ops:?}");
    for op in ops {
        let keys: Vec<&String> = op.as_object().unwrap().keys().collect();
        assert!(
            !keys.iter().any(|k| k.contains("actor")),
            "an op named its actor: {keys:?}"
        );
    }
}

/// A cursor past the head is what a Litestream restore produces, and a client
/// that is never told to reset stalls on it silently and forever.
#[tokio::test]
async fn an_op_cursor_past_the_head_resets() {
    let (store, app, _guard) = world().await;
    let (token, user) = register(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let id = send(&store, channel, user, "one").await;
    store.edit_message(id, "revised", user).await.unwrap();

    let (_, body) = sync(
        &app,
        &token,
        json!([{ "channel_id": channel.to_string(), "after_seq": 99, "after_op_seq": 500 }]),
    )
    .await;
    assert_eq!(body["scopes"][0]["reset"], true);
    assert_eq!(body["scopes"][0]["ops"].as_array().unwrap().len(), 0);
}

/// The message half has the same restore case as the op half: a message cursor
/// past the channel head must reset even when no op cursor is sent.
#[tokio::test]
async fn a_message_cursor_past_the_head_resets() {
    let (store, app, _guard) = world().await;
    let (token, user) = register(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    send(&store, channel, user, "one").await;

    let (_, body) = sync(
        &app,
        &token,
        json!([{ "channel_id": channel.to_string(), "after_seq": 99, "after_op_seq": 0 }]),
    )
    .await;
    assert_eq!(body["scopes"][0]["reset"], true);
    assert_eq!(body["scopes"][0]["messages"].as_array().unwrap().len(), 0);
}

/// Content is the message's *current* text, so a message edited many times is
/// that many copies of one string without the collapse.
#[tokio::test]
async fn only_the_last_edit_of_a_message_in_a_page_carries_content() {
    let (store, app, _guard) = world().await;
    let (token, user) = register(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let id = send(&store, channel, user, "one").await;
    for i in 0..5 {
        store
            .edit_message(id, &format!("revision {i}"), user)
            .await
            .unwrap();
    }

    let (_, body) = sync(
        &app,
        &token,
        json!([{ "channel_id": channel.to_string(), "after_seq": 99, "after_op_seq": 0 }]),
    )
    .await;
    let ops = body["scopes"][0]["ops"].as_array().unwrap();
    assert_eq!(
        ops.len(),
        5,
        "every op keeps its row, so the cursor advances"
    );
    let with_content: Vec<i64> = ops
        .iter()
        .filter(|o| o.get("content").is_some())
        .map(|o| o["seq"].as_i64().unwrap())
        .collect();
    assert_eq!(
        with_content,
        vec![5],
        "only the newest op names the text, and it is the current text"
    );
    assert_eq!(ops[4]["content"], "revision 4");
    let seqs: Vec<i64> = ops.iter().map(|o| o["seq"].as_i64().unwrap()).collect();
    assert_eq!(seqs, vec![1, 2, 3, 4, 5], "collapsing must leave no hole");
}

/// Batching the permission check must not collapse per-channel visibility: a
/// caller who can see one channel of a multi-scope sync but not another gets
/// exactly the first and never the second. This is the risk the batched
/// `permissions_in_channels` introduces over the old per-scope check, so it
/// gets its own test rather than trusting the single-scope one above.
#[tokio::test]
async fn a_mixed_sync_returns_only_the_channels_the_caller_can_view() {
    let (store, app, _guard) = world().await;
    let (_root, owner) = register(&store, "root").await;
    let visible = store.list_channels().await.unwrap()[0].id;
    let hidden = store.create_channel("secret", "text").await.unwrap().id;
    send(&store, visible, owner, "seen").await;
    send(&store, hidden, owner, "unseen").await;

    let stranger = store
        .create_account("bystander", "bystander", "not-a-real-hash")
        .await
        .unwrap();
    store
        .set_member_overwrite(
            hidden,
            stranger.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let token = store
        .open_session(stranger.id, "cli")
        .await
        .unwrap()
        .access_token;

    let (status, body) = sync(
        &app,
        &token,
        json!([
            { "channel_id": visible.to_string(), "after_seq": 0, "after_op_seq": 0 },
            { "channel_id": hidden.to_string(), "after_seq": 0, "after_op_seq": 0 }
        ]),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let scopes = body["scopes"].as_array().unwrap();
    assert_eq!(scopes.len(), 1, "only the visible channel: {body}");
    assert_eq!(scopes[0]["channel_id"], visible.to_string(), "{body}");
}

/// The scope is skipped entirely before anything is read, so a caller with no
/// view of the channel learns nothing about its op stream either.
#[tokio::test]
async fn a_caller_without_view_gets_no_scope_at_all() {
    let (store, app, _guard) = world().await;
    let (_root, owner) = register(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let id = send(&store, channel, owner, "one").await;
    store.edit_message(id, "revised", owner).await.unwrap();

    let stranger = store
        .create_account("bystander", "bystander", "not-a-real-hash")
        .await
        .unwrap();
    store
        .set_member_overwrite(
            channel,
            stranger.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let token = store
        .open_session(stranger.id, "cli")
        .await
        .unwrap()
        .access_token;

    let (status, body) = sync(
        &app,
        &token,
        json!([{ "channel_id": channel.to_string(), "after_seq": 0, "after_op_seq": 0 }]),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(
        body["scopes"].as_array().unwrap().is_empty(),
        "the scope must be absent, not empty: {body}"
    );
}

/// The byte budget has to bind the message half, not only the op half.
///
/// Three channels of a hundred 4000-byte messages is about 1.2 MB, past the
/// 1 MiB the module doc promises a `/sync` response stays under. Before this
/// the budget was subtracted after each page was already fetched whole, so
/// nothing ever cut a page and the promise held only for ops.
#[tokio::test]
async fn the_byte_budget_cuts_the_message_half_and_reports_more() {
    let (store, app, _guard) = world().await;
    let (token, user) = register(&store, "root").await;
    let mut channels = vec![store.list_channels().await.unwrap()[0].id];
    for name in ["second", "third"] {
        channels.push(store.create_channel(name, "text").await.unwrap().id);
    }
    let body = "x".repeat(4000);
    for &channel in &channels {
        for _ in 0..100 {
            send(&store, channel, user, &body).await;
        }
    }

    let scopes: Vec<Value> = channels
        .iter()
        .map(|c| json!({ "channel_id": c.to_string(), "after_seq": 0 }))
        .collect();
    let (status, response) = sync(&app, &token, Value::Array(scopes)).await;
    assert_eq!(status, StatusCode::OK, "{response}");

    let returned = response["scopes"].as_array().unwrap();
    assert_eq!(returned.len(), 3);
    let total_bytes: usize = returned
        .iter()
        .flat_map(|s| s["messages"].as_array().unwrap())
        .map(|m| m["content"].as_str().unwrap().len())
        .sum();
    assert!(
        total_bytes <= 1024 * 1024,
        "the response carried {total_bytes} bytes of message content, past the 1 MiB budget"
    );
    let cut = returned
        .iter()
        .find(|s| s["messages"].as_array().unwrap().len() < 100)
        .expect("one scope must have been cut short by the budget");
    assert_eq!(
        cut["has_more"], true,
        "a page cut by the budget must tell the client to ask again"
    );
    let full: usize = returned
        .iter()
        .filter(|s| s["messages"].as_array().unwrap().len() == 100)
        .count();
    assert_eq!(
        full, 2,
        "the budget admits two whole scopes before it cuts the third"
    );
}
