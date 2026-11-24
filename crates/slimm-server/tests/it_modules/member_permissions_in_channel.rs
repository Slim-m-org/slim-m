// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The bot-only member-permissions read scoped to one channel, so a bot
//! checks the invoker's own rights there instead of acting with its own.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::call_as as call;
use support::overwrite_harness::{app, new_store, register};

async fn make_bot(router: &Router, root: &str) -> (String, String) {
    let body = json!({ "username": "reader" });
    let (status, created) = call(router, "POST", "/bots", root, Some(body)).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    (
        created["bot"]["user_id"].as_str().unwrap().to_owned(),
        created["token"].as_str().unwrap().to_owned(),
    )
}

async fn voice_channel(router: &Router, root: &str) -> String {
    let body = json!({ "name": "lounge", "kind": "voice" });
    let (status, channel) = call(router, "POST", "/channels", root, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{channel}");
    channel["id"].as_str().unwrap().to_owned()
}

async fn deny_member(router: &Router, root: &str, channel: &str, user: &str, deny: Permissions) {
    let uri = format!("/channels/{channel}/overwrites/member/{user}");
    let body = json!({ "allow": 0, "deny": deny.bits() });
    let (status, out) = call(router, "PUT", &uri, root, Some(body)).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{out}");
}

async fn bits(router: &Router, bot: &str, user: &str, channel: &str) -> (StatusCode, Value) {
    let uri = format!("/members/{user}/permissions?channel_id={channel}");
    call(router, "GET", &uri, bot, None).await
}

fn has(body: &Value, bit: Permissions) -> bool {
    body["permissions"].as_i64().unwrap() & bit.bits() == bit.bits()
}

#[tokio::test]
async fn a_channel_overwrite_shows_in_the_members_channel_bits() {
    let (store, _guard) = new_store("slimm-memberperms-chan").await;
    let (root, _) = register(&store, "root").await;
    let (alice, alice_id) = register(&store, "alice").await;
    let router = app(store);
    let (_, bot) = make_bot(&router, &root).await;
    let channel = voice_channel(&router, &root).await;
    let spectator = Permissions::USE_CANVAS.union(Permissions::SPEAK);
    deny_member(&router, &root, &channel, &alice_id, spectator).await;

    let (status, body) = bits(&router, &bot, &alice_id, &channel).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["user_id"], alice_id);
    assert_eq!(body["channel_id"], channel);
    assert!(has(&body, Permissions::VIEW_CHANNEL));
    assert!(!has(&body, Permissions::USE_CANVAS), "{body}");
    assert!(!has(&body, Permissions::SPEAK), "{body}");

    let uri = format!("/channels/{channel}/permissions");
    let (_, own) = call(&router, "GET", &uri, &alice, None).await;
    assert_eq!(body["permissions"], own["permissions"]);
}

#[tokio::test]
async fn a_channel_either_side_cannot_view_answers_zero() {
    let (store, _guard) = new_store("slimm-memberperms-hidden").await;
    let (root, _) = register(&store, "root").await;
    let (_, alice_id) = register(&store, "alice").await;
    let (_, bob_id) = register(&store, "bob").await;
    let router = app(store);
    let (bot_id, bot) = make_bot(&router, &root).await;
    let hidden_from_bot = voice_channel(&router, &root).await;
    deny_member(
        &router,
        &root,
        &hidden_from_bot,
        &bot_id,
        Permissions::VIEW_CHANNEL,
    )
    .await;
    let hidden_from_bob = voice_channel(&router, &root).await;
    deny_member(
        &router,
        &root,
        &hidden_from_bob,
        &bob_id,
        Permissions::VIEW_CHANNEL,
    )
    .await;

    let (status, body) = bits(&router, &bot, &alice_id, &hidden_from_bot).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["permissions"], 0, "the bot cannot view it");
    let (_, body) = bits(&router, &bot, &bob_id, &hidden_from_bob).await;
    assert_eq!(body["permissions"], 0, "the member cannot view it");
    let missing = uuid::Uuid::now_v7().to_string();
    let (status, body) = bits(&router, &bot, &alice_id, &missing).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["permissions"], 0, "no such channel");
    let (status, _) = bits(&router, &bot, &alice_id, "not-a-uuid").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}
