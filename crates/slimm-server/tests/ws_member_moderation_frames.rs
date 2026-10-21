// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The deployment-wide moderation events reach a connected client as frames.
//! `authorize` delivers them to every session with nothing per-viewer to
//! resolve, and cargo-mutants showed no test held it to that: deleting any of
//! the match arms let the event fall through to the channel-scoped path and
//! vanish, with the suite still green. A client that never hears a timeout,
//! removal, restore or join keeps showing the member list as it was.
//!
//! `MemberJoined` is not a moderation event, but it is authorized the same
//! deployment-wide way (see `hub/event.rs`'s own doc comment for why it does
//! not also fire on a restore), so it is covered here rather than starting a
//! third near-identical harness.
//!
//! Its own binary rather than another case in `tests/ws.rs`, which sits at the
//! file-budget ceiling; the connect and read helpers are the same ones.

use std::time::Duration;

use serde_json::Value;
use slimm_server::hub::Event;

mod support;

use support::ws::{Client, connect, read_frame_skipping_presence, serve, user_ticket_and_id};

async fn next_frame(ws: &mut Client) -> Value {
    tokio::time::timeout(Duration::from_secs(2), read_frame_skipping_presence(ws))
        .await
        .expect("the frame must arrive; a dropped moderation event leaves a client stale")
}

#[tokio::test]
async fn a_timeout_a_removal_and_a_restore_each_reach_a_connected_client() {
    let (store, _guard) = support::new_store("slimm-ws-moderation").await;
    let state = support::app::state(store.clone());
    let (_alice_ticket, alice) = user_ticket_and_id(&store, "alice").await;
    let (bob_ticket, _bob) = user_ticket_and_id(&store, "bob").await;
    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    state.hub.publish(Event::MemberTimeoutChanged {
        user_id: alice,
        until: Some(12_345),
    });
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.timeout");
    assert_eq!(frame["user_id"], alice.to_string());
    assert_eq!(frame["until"], 12_345);

    state.hub.publish(Event::MemberTimeoutChanged {
        user_id: alice,
        until: None,
    });
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.timeout");
    assert!(
        frame["until"].is_null(),
        "a lifted timeout is announced as null: {frame}"
    );

    state.hub.publish(Event::MemberRemoved(alice));
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.removed");
    assert_eq!(frame["user_id"], alice.to_string());

    state.hub.publish(Event::MemberRestored(alice));
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.restored");
    assert_eq!(frame["user_id"], alice.to_string());

    state.hub.publish(Event::MemberJoined(alice));
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.joined");
    assert_eq!(frame["user_id"], alice.to_string());
}
