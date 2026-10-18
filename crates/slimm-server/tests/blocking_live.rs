// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Blocking on the live socket, against a real server on an ephemeral port.
//!
//! A reaction tally is per viewer - a reactor the receiver has blocked is not
//! counted for them - so it has to be derived per receiving connection, the way
//! `presence.changed`'s status already is. The first version of that filter went
//! into the store's read only, which left the broadcast computing one global
//! tally and fanning it out, and the client replaces its cached tally with
//! whatever a frame says. So a single reaction from a blocked person put their
//! count back on screen for everybody who had blocked them, and nothing in
//! `blocking_reach.rs` could see it: that file drives the store, and the store
//! was right.
//!
//! Its own file rather than added to `ws.rs` (429 lines), which is past the
//! review budget already; the harness is duplicated, as it is in every other
//! file in this suite.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A user, their REST access token, and a WebSocket connect ticket.
async fn user_ticket(store: &Store, name: &str) -> (String, String, UserId) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (tokens.access_token, ticket, user.id)
}

async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    let ack = read_frame(&mut ws).await;
    assert_eq!(ack["type"], "hello");
    ws
}

/// The next frame of `kind`, skipping the presence chatter every connect on the
/// shared hub publishes and anything else this test is not about.
async fn next_frame_of(ws: &mut Client, kind: &str) -> Value {
    let deadline = Duration::from_secs(3);
    loop {
        let frame = tokio::time::timeout(deadline, read_frame(ws))
            .await
            .unwrap_or_else(|_| panic!("no {kind} frame arrived"));
        if frame["type"] == kind {
            return frame;
        }
    }
}

async fn read_frame(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                return serde_json::from_str(text.as_str()).unwrap();
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

/// The same reaction, on the same message, reported differently to two live
/// sockets: absent for the blocker, present for everybody else.
///
/// Both sides are asserted in one run deliberately. A test that only read the
/// blocker's frame would pass just as well against a server that dropped the
/// reaction for the whole room, which is the moderation action blocking is
/// deliberately not.
#[tokio::test]
async fn a_live_reaction_from_a_blocked_user_is_absent_for_the_blocker_alone() {
    let (store, _guard) = support::new_store("slimm-blocking-live").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ADD_REACTIONS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (pest_access, _pest_ticket, pest) = user_ticket(&store, "pest").await;
    let (_carol_access, carol_ticket, _carol) = user_ticket(&store, "carol").await;

    let message = store
        .send_message(NewMessage::plain(
            channel.id,
            alice,
            slimm_server::ids::MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap()
        .message
        .id;
    store.block_user(alice, pest).await.unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let uri = format!("/messages/{message}/reactions/:wave:");
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(&uri)
                .header("authorization", format!("Bearer {pest_access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let for_alice = next_frame_of(&mut alice_ws, "reactions.changed").await;
    assert_eq!(
        for_alice["reactions"].as_array().unwrap().len(),
        0,
        "the blocker's frame must not carry a blocked reactor's count: {for_alice}"
    );

    let for_carol = next_frame_of(&mut carol_ws, "reactions.changed").await;
    let carols = for_carol["reactions"].as_array().unwrap();
    assert_eq!(
        carols.len(),
        1,
        "nothing was removed for anybody else: {for_carol}"
    );
    assert_eq!(carols[0]["emoji"], ":wave:");
    assert_eq!(carols[0]["count"], 1);

    // Her own reaction still reaches her: the filter is about the reactor.
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(&uri)
                .header("authorization", format!("Bearer {alice_access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let for_alice = next_frame_of(&mut alice_ws, "reactions.changed").await;
    let hers = for_alice["reactions"].as_array().unwrap();
    assert_eq!(
        hers.len(),
        1,
        "her own reaction is hers to see: {for_alice}"
    );
    assert_eq!(hers[0]["count"], 1, "and counts only herself");
}

/// A second, non-blocked reactor on the same emoji a blocked person also
/// used: the blocker's frame still shows the emoji, counting only the
/// reactor they have not blocked, and every reaction object on the wire
/// carries exactly `emoji` and `count` - never a reactor id, not even for the
/// one reactor left standing after the exclusion.
///
/// This is the SRV1 path: the server now computes `reaction_reactors` once
/// per event and filters per connection with `blocked_among`, rather than
/// re-running the old per-viewer `reactions_for_message` query for every
/// connection. The wire shape this test checks is exactly what guarded the
/// old path too, so a regression in either the computation or the filtering
/// step fails here the same way.
#[tokio::test]
async fn a_live_reactions_frame_never_carries_a_reactor_id_and_mixes_blocked_with_unblocked() {
    let (store, _guard) = support::new_store("slimm-blocking-live").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ADD_REACTIONS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());

    let (_alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (pest_access, _pest_ticket, pest) = user_ticket(&store, "pest").await;
    let (carol_access, _carol_ticket, _carol) = user_ticket(&store, "carol").await;

    let message = store
        .send_message(NewMessage::plain(
            channel.id,
            alice,
            slimm_server::ids::MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap()
        .message
        .id;
    store.block_user(alice, pest).await.unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;

    let uri = format!("/messages/{message}/reactions/:wave:");
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(&uri)
                .header("authorization", format!("Bearer {pest_access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let for_alice = next_frame_of(&mut alice_ws, "reactions.changed").await;
    assert_eq!(
        for_alice["reactions"].as_array().unwrap().len(),
        0,
        "the only reactor on this emoji is blocked, so the emoji is absent, not zero: {for_alice}"
    );

    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(&uri)
                .header("authorization", format!("Bearer {carol_access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let for_alice = next_frame_of(&mut alice_ws, "reactions.changed").await;
    let reactions = for_alice["reactions"].as_array().unwrap();
    assert_eq!(
        reactions.len(),
        1,
        "carol's unblocked reaction brings the emoji back: {for_alice}"
    );
    assert_eq!(reactions[0]["emoji"], ":wave:");
    assert_eq!(
        reactions[0]["count"], 1,
        "pest still does not count, only carol does: {for_alice}"
    );

    let mut keys: Vec<&String> = reactions[0].as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(
        keys,
        vec!["count", "emoji"],
        "the wire object must carry only emoji and count, never a reactor id: {for_alice}"
    );
}

/// A blocked reactor's early timestamp must not be able to shift where an
/// emoji sorts for the blocker: `apple` gets a blocked reactor's reaction
/// first, then `banana` gets an unblocked one, then `apple` gets a second,
/// unblocked reaction. Unfiltered, `apple` would sort first (it was reacted
/// to first, by anybody). For the blocker, `apple`'s only *visible* reactor
/// reacted last, so `banana` must sort first; a non-blocking viewer sees the
/// unfiltered order, `apple` before `banana`.
///
/// This is the ordering half of SRV1: `reaction_reactors` hands `authorize`
/// every reactor's own timestamp rather than a pre-reduced `first_at`,
/// specifically so this per-viewer reduction can happen downstream, the same
/// place the old `reactions_for_messages` query did it (`first_at` computed
/// after excluding blocked reactors, not before).
#[tokio::test]
async fn a_blocked_reactors_early_timestamp_cannot_reorder_an_emoji_for_the_blocker() {
    let (store, _guard) = support::new_store("slimm-blocking-live").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ADD_REACTIONS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());

    let (_alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_dana_access, dana_ticket, _dana) = user_ticket(&store, "dana").await;
    let (pest_access, _pest_ticket, pest) = user_ticket(&store, "pest").await;
    let (yara_access, _yara_ticket, _yara) = user_ticket(&store, "yara").await;
    let (zane_access, _zane_ticket, _zane) = user_ticket(&store, "zane").await;

    let message = store
        .send_message(NewMessage::plain(
            channel.id,
            alice,
            slimm_server::ids::MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap()
        .message
        .id;
    store.block_user(alice, pest).await.unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut dana_ws = connect(addr, &dana_ticket).await;

    let apple_uri = format!("/messages/{message}/reactions/:apple:");
    let banana_uri = format!("/messages/{message}/reactions/:banana:");

    let react = |uri: String, access: String| {
        let state = state.clone();
        async move {
            let response = http::router(state)
                .oneshot(
                    Request::builder()
                        .method("PUT")
                        .uri(&uri)
                        .header("authorization", format!("Bearer {access}"))
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NO_CONTENT);
        }
    };

    // pest (blocked by alice) reacts apple first.
    react(apple_uri.clone(), pest_access).await;
    next_frame_of(&mut alice_ws, "reactions.changed").await;
    next_frame_of(&mut dana_ws, "reactions.changed").await;
    tokio::time::sleep(Duration::from_millis(15)).await;

    // yara reacts banana second.
    react(banana_uri, yara_access).await;
    next_frame_of(&mut alice_ws, "reactions.changed").await;
    next_frame_of(&mut dana_ws, "reactions.changed").await;
    tokio::time::sleep(Duration::from_millis(15)).await;

    // zane reacts apple third, the only visible reactor on it for alice.
    react(apple_uri, zane_access).await;
    let for_alice = next_frame_of(&mut alice_ws, "reactions.changed").await;
    let for_dana = next_frame_of(&mut dana_ws, "reactions.changed").await;

    let alice_order: Vec<&str> = for_alice["reactions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["emoji"].as_str().unwrap())
        .collect();
    assert_eq!(
        alice_order,
        vec![":banana:", ":apple:"],
        "apple's only visible reactor for alice reacted last, so banana sorts first: {for_alice}"
    );

    let dana_order: Vec<&str> = for_dana["reactions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["emoji"].as_str().unwrap())
        .collect();
    assert_eq!(
        dana_order,
        vec![":apple:", ":banana:"],
        "dana blocks nobody, so the unfiltered order holds: apple was reacted to first: {for_dana}"
    );
}
