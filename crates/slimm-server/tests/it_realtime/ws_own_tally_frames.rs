// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What `reactions.changed` and `poll.voted` tell each connection about its own
//! user, so the same account's other devices follow a reaction or a vote, and
//! the version that lets a client keep the newer of two frames.

use axum::Router;
use serde_json::{Value, json};
use slimm_server::http::{self};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{json_body, request};
use support::ws::{Client, connect, read_frame_of_type, serve, user_ticket};

/// A second signed-in device for `user`: its own session and ws ticket.
async fn second_device(store: &Store, user: UserId) -> String {
    let tokens = store.open_session(user, "phone").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    store.mint_ws_ticket(&ctx).await.unwrap().0
}

async fn space(prefix: &str) -> (Store, support::TestDbGuard, ChannelId) {
    let (store, guard) = support::new_store(prefix).await;
    let everyone = Permissions::VIEW_CHANNEL
        .union(Permissions::SEND_MESSAGES)
        .union(Permissions::ADD_REACTIONS);
    store.create_role("everyone", everyone, true).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    (store, guard, channel.id)
}

async fn send(router: &Router, method: &str, uri: &str, token: &str, body: Option<Value>) {
    let response = router
        .clone()
        .oneshot(request(method, uri, Some(token), body))
        .await
        .unwrap();
    assert!(
        response.status().is_success(),
        "{method} {uri}: {}",
        response.status()
    );
}

fn reacted(frame: &Value, emoji: &str) -> Option<bool> {
    frame["reactions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["emoji"] == emoji)
        .map(|r| {
            r["reacted"]
                .as_bool()
                .expect("every row says whether it is the viewer's")
        })
}

async fn reactions_frame(ws: &mut Client) -> Value {
    read_frame_of_type(ws, "reactions.changed").await
}

/// A reaction on one device reaches the account's other device as its own, and nobody else's.
#[tokio::test]
async fn a_reaction_on_one_device_is_marked_as_yours_on_the_other() {
    let (store, _guard, channel) = space("slimm-own-reaction").await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let phone_ticket = second_device(&store, alice).await;
    let message = store
        .send_message(NewMessage::plain(
            channel,
            alice,
            MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap()
        .message
        .id;

    let addr = serve(state.clone()).await;
    let mut desktop = connect(addr, &alice_ticket).await;
    let mut phone = connect(addr, &phone_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let router = http::router(state);
    let uri = format!("/messages/{message}/reactions/:wave:");

    send(&router, "PUT", &uri, &alice_access, None).await;
    let on_phone = reactions_frame(&mut phone).await;
    assert_eq!(reacted(&on_phone, ":wave:"), Some(true), "{on_phone}");
    let on_desktop = reactions_frame(&mut desktop).await;
    assert_eq!(reacted(&on_desktop, ":wave:"), Some(true), "{on_desktop}");
    let for_bob = reactions_frame(&mut bob_ws).await;
    assert_eq!(reacted(&for_bob, ":wave:"), Some(false), "{for_bob}");
    assert_eq!(for_bob["reactions"][0]["count"], 1);

    send(&router, "DELETE", &uri, &alice_access, None).await;
    let removed = reactions_frame(&mut phone).await;
    assert_eq!(reacted(&removed, ":wave:"), None, "{removed}");
    assert!(
        removed["version"].as_i64().unwrap() > on_phone["version"].as_i64().unwrap(),
        "a later change carries a larger version: {on_phone} then {removed}"
    );
}

async fn create_poll(router: &Router, channel: ChannelId, token: &str) -> String {
    let body = json!({
        "id": Uuid::now_v7().to_string(),
        "question": "lunch?",
        "options": ["soup", "salad"],
    });
    let uri = format!("/channels/{channel}/messages/polls");
    let response = router
        .clone()
        .oneshot(request("POST", &uri, Some(token), Some(body)))
        .await
        .unwrap();
    json_body(response).await["id"].as_str().unwrap().to_owned()
}

/// A vote reaches the voter's other device with their choice, and every other viewer without it.
#[tokio::test]
async fn a_vote_on_one_device_reaches_the_other_with_the_choice() {
    let (store, _guard, channel) = space("slimm-own-vote").await;
    let state = support::app::state(store.clone());
    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let phone_ticket = second_device(&store, alice).await;
    let addr = serve(state.clone()).await;
    let mut phone = connect(addr, &phone_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let router = http::router(state);
    let poll = create_poll(&router, channel, &alice_access).await;
    let vote_uri = format!("/messages/{poll}/polls/vote");

    send(
        &router,
        "PUT",
        &vote_uri,
        &alice_access,
        Some(json!({ "option": 1 })),
    )
    .await;
    let first = read_frame_of_type(&mut phone, "poll.voted").await;
    assert_eq!(first["voted_option"], 1, "{first}");
    let for_bob = read_frame_of_type(&mut bob_ws, "poll.voted").await;
    assert!(for_bob.get("voted_option").is_none(), "{for_bob}");
    assert_eq!(for_bob["options"][1]["votes"], 1);

    send(
        &router,
        "PUT",
        &vote_uri,
        &alice_access,
        Some(json!({ "option": 0 })),
    )
    .await;
    let changed = read_frame_of_type(&mut phone, "poll.voted").await;
    assert_eq!(changed["voted_option"], 0, "{changed}");
    assert!(
        changed["version"].as_i64().unwrap() > first["version"].as_i64().unwrap(),
        "a later vote carries a larger version: {first} then {changed}"
    );
}
