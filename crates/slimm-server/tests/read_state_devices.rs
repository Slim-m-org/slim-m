// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Read state across one account's devices: a read on one device clears the
//! badge on the others, your own send is never unread to you, and push skips
//! a message the recipient already read or has open.

use std::collections::HashSet;
use std::time::Duration;

use axum::http::StatusCode;
use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, DeviceId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::presence::PresenceTracker;
use slimm_server::store::{NewMessage, Store};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::ws::{Client, connect, read_frame_skipping_presence, serve};

use support::app::request_json as request;

async fn seed_everyone(store: &Store) {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
}

/// One more device for `user`: (rest access token, ws connect ticket).
async fn device(store: &Store, user: UserId) -> (String, String) {
    let tokens = store.open_session(user, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (tokens.access_token, ticket)
}

/// A new account with its first device: (user id, token, ticket).
async fn account(store: &Store, name: &str) -> (UserId, String, String) {
    let user = store.create_user(name, name).await.unwrap();
    let (token, ticket) = device(store, user.id).await;
    (user.id, token, ticket)
}

async fn frame_within(ws: &mut Client, within: Duration) -> Option<Value> {
    tokio::time::timeout(within, read_frame_skipping_presence(ws))
        .await
        .ok()
}

/// Reads frames until one of `kind` arrives; `None` once the socket goes quiet.
async fn frame_of_kind(ws: &mut Client, kind: &str) -> Option<Value> {
    while let Some(frame) = frame_within(ws, Duration::from_millis(500)).await {
        if frame["type"] == kind {
            return Some(frame);
        }
    }
    None
}

async fn send(state: &AppState, token: &str, channel: ChannelId) -> Value {
    let response = http::router(state.clone())
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            token,
            json!({ "id": Uuid::now_v7().to_string(), "content": "hello" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn a_read_on_one_device_reaches_the_same_accounts_other_device_only() {
    let (store, _guard) = support::new_store("slimm-read-state-devices").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice, phone_token, _phone_ticket) = account(&store, "alice").await;
    let (_desktop_token, desktop_ticket) = device(&store, alice).await;
    let (_bob, bob_token, bob_ticket) = account(&store, "bob").await;
    send(&state, &bob_token, channel.id).await;

    let addr = serve(state.clone()).await;
    let mut desktop = connect(addr, &desktop_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let response = http::router(state.clone())
        .oneshot(request(
            "PUT",
            &format!("/channels/{}/read", channel.id),
            &phone_token,
            json!({ "seq": 1 }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = frame_of_kind(&mut desktop, "read_state.changed")
        .await
        .expect("the other device must hear about the read");
    assert_eq!(frame["channel_id"], channel.id.to_string());
    assert_eq!(frame["last_read_seq"], 1);

    let leaked = frame_within(&mut bob_ws, Duration::from_millis(300)).await;
    assert!(
        leaked.is_none(),
        "another account must hear nothing: {leaked:?}"
    );
}

#[tokio::test]
async fn sending_advances_your_own_marker_on_every_device_and_nobody_elses() {
    let (store, _guard) = support::new_store("slimm-read-state-devices").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice, phone_token, _phone_ticket) = account(&store, "alice").await;
    let (_desktop_token, desktop_ticket) = device(&store, alice).await;
    let (bob, _bob_token, bob_ticket) = account(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut desktop = connect(addr, &desktop_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let message = send(&state, &phone_token, channel.id).await;
    assert_eq!(message["seq"], 1);

    let frame = frame_of_kind(&mut desktop, "read_state.changed")
        .await
        .expect("the author's other device must clear its badge");
    assert_eq!(frame["last_read_seq"], 1);
    assert_eq!(store.unread_count(alice, channel.id).await.unwrap(), 0);

    assert_eq!(
        store.unread_count(bob, channel.id).await.unwrap(),
        1,
        "the recipient still has it unread"
    );
    let bob_frame = frame_of_kind(&mut bob_ws, "read_state.changed").await;
    assert!(
        bob_frame.is_none(),
        "another account must not get the frame"
    );
}

#[tokio::test]
async fn push_skips_a_recipient_who_read_or_is_viewing_the_channel() {
    let (store, _guard) = support::new_store("slimm-read-state-devices").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let other = store.create_channel("random", "text").await.unwrap();
    let author = store.create_user("author", "Author").await.unwrap().id;
    let read = store.create_user("read", "Read").await.unwrap().id;
    let watching = store.create_user("watching", "Watching").await.unwrap().id;
    let elsewhere = store
        .create_user("elsewhere", "Elsewhere")
        .await
        .unwrap()
        .id;
    let behind = store.create_user("behind", "Behind").await.unwrap().id;
    let mut seq = slimm_server::ids::Seq(0);
    for _ in 0..2 {
        let sent = store
            .send_message(NewMessage::plain(
                channel.id,
                author,
                MessageId::generate(),
                "hi",
            ))
            .await
            .unwrap();
        seq = sent.message.seq;
    }
    store.mark_read(read, channel.id, seq.0).await.unwrap();
    store
        .mark_read(behind, channel.id, seq.0 - 1)
        .await
        .unwrap();

    let viewing = PresenceTracker::new().viewing();
    viewing.set(
        watching,
        DeviceId::generate(),
        1,
        HashSet::from([channel.id]),
    );
    viewing.set(
        elsewhere,
        DeviceId::generate(),
        1,
        HashSet::from([other.id]),
    );

    let candidates = vec![read, watching, elsewhere, behind];
    let kept =
        slimm_server::push::narrow_for_attention(&store, channel.id, seq, &viewing, candidates)
            .await
            .unwrap();
    assert_eq!(kept, vec![elsewhere, behind]);
}

#[tokio::test]
async fn a_viewing_frame_is_recorded_and_forgotten_when_the_socket_closes() {
    let (store, _guard) = support::new_store("slimm-read-state-devices").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice, _token, ticket) = account(&store, "alice").await;
    let addr = serve(state.clone()).await;
    let mut ws = connect(addr, &ticket).await;
    let viewing = state.hub.presence().viewing();
    let open = json!({ "type": "viewing", "channel_ids": [channel.id.to_string(), "not-a-uuid"] });

    ws.send(WsMessage::Text(open.to_string())).await.unwrap();
    support::wait::wait_until("the socket to register alice as viewing", || {
        viewing.is_viewing(alice, channel.id)
    })
    .await;

    let close = json!({ "type": "viewing", "channel_ids": [] });
    ws.send(WsMessage::Text(close.to_string())).await.unwrap();
    support::wait::wait_until("alice to stop viewing", || {
        !viewing.is_viewing(alice, channel.id)
    })
    .await;

    ws.send(WsMessage::Text(open.to_string())).await.unwrap();
    support::wait::wait_until("the socket to register alice as viewing", || {
        viewing.is_viewing(alice, channel.id)
    })
    .await;
    ws.close(None).await.unwrap();
    drop(ws);
    support::wait::wait_until("alice to stop viewing", || {
        !viewing.is_viewing(alice, channel.id)
    })
    .await;
}

async fn report_lifecycle(state: &AppState, token: &str, label: &str) {
    let response = http::router(state.clone())
        .oneshot(request(
            "PUT",
            "/push/lifecycle",
            token,
            json!({ "state": label }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_device_that_reports_background_stops_being_counted_as_viewing() {
    let (store, _guard) = support::new_store("slimm-read-state-devices").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice, phone_token, phone_ticket) = account(&store, "alice").await;
    let (laptop_token, laptop_ticket) = device(&store, alice).await;
    let addr = serve(state.clone()).await;
    let mut phone = connect(addr, &phone_ticket).await;
    let mut laptop = connect(addr, &laptop_ticket).await;
    let viewing = state.hub.presence().viewing();
    let open = json!({ "type": "viewing", "channel_ids": [channel.id.to_string()] });
    phone.send(WsMessage::Text(open.to_string())).await.unwrap();
    laptop
        .send(WsMessage::Text(open.to_string()))
        .await
        .unwrap();
    support::wait::wait_until("the socket to register alice as viewing", || {
        viewing.is_viewing(alice, channel.id)
    })
    .await;

    report_lifecycle(&state, &phone_token, "foreground").await;
    assert!(viewing.is_viewing(alice, channel.id));

    report_lifecycle(&state, &phone_token, "background").await;
    assert!(
        viewing.is_viewing(alice, channel.id),
        "the laptop still reports it"
    );

    report_lifecycle(&state, &laptop_token, "background").await;
    assert!(!viewing.is_viewing(alice, channel.id));
}

#[tokio::test]
async fn a_device_that_reports_background_stops_marking_the_account_active() {
    let (store, _guard) = support::new_store("slimm-read-state-devices").await;
    seed_everyone(&store).await;
    let state = support::app::state(store.clone());
    let (alice, phone_token, phone_ticket) = account(&store, "alice").await;
    let (laptop_token, laptop_ticket) = device(&store, alice).await;
    let addr = serve(state.clone()).await;
    let mut phone = connect(addr, &phone_ticket).await;
    let mut laptop = connect(addr, &laptop_ticket).await;
    let viewing = state.hub.presence().viewing();
    let active = json!({ "type": "viewing", "channel_ids": [], "active": true });
    phone
        .send(WsMessage::Text(active.to_string()))
        .await
        .unwrap();
    laptop
        .send(WsMessage::Text(active.to_string()))
        .await
        .unwrap();
    support::wait::wait_until("both devices to count as active", || {
        viewing
            .active_devices_at(alice, std::time::Instant::now())
            .len()
            == 2
    })
    .await;

    report_lifecycle(&state, &phone_token, "background").await;
    assert!(
        viewing.is_recently_active(alice),
        "the laptop is still in use"
    );

    report_lifecycle(&state, &laptop_token, "background").await;
    assert!(!viewing.is_recently_active(alice));
}

#[tokio::test]
async fn a_read_beyond_the_channel_head_announces_the_clamped_marker() {
    let (store, _guard) = support::new_store("slimm-read-state-devices").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice, phone_token, _phone_ticket) = account(&store, "alice").await;
    let (_desktop_token, desktop_ticket) = device(&store, alice).await;
    let (_bob, bob_token, _bob_ticket) = account(&store, "bob").await;
    send(&state, &bob_token, channel.id).await;
    let addr = serve(state.clone()).await;
    let mut desktop = connect(addr, &desktop_ticket).await;

    let response = http::router(state.clone())
        .oneshot(request(
            "PUT",
            &format!("/channels/{}/read", channel.id),
            &phone_token,
            json!({ "seq": 99 }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = frame_of_kind(&mut desktop, "read_state.changed")
        .await
        .expect("the other device must hear about the read");
    assert_eq!(
        frame["last_read_seq"], 1,
        "the stored marker, not the asked-for 99"
    );
}
