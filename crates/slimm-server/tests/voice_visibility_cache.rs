// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice join is gated on the joiner's chosen visibility, read from the
//! presence tracker's cache while they are connected instead of the store.

use std::time::Duration;

use serde_json::Value;
use slimm_server::hub::Event;
use slimm_server::permissions::Permissions;
use slimm_server::presence::Visibility;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket_and_id};

async fn joined_frame(ws: &mut Client, wait: Duration) -> Option<Value> {
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        let frame = tokio::time::timeout(left, read_frame(ws)).await.ok()?;
        if frame["type"] == "voice.participant_joined" {
            return Some(frame);
        }
    }
}

#[tokio::test]
async fn the_cached_visibility_decides_a_voice_join_not_a_store_read() {
    let (store, _guard) = support::new_store("slimm-voice-visibility-cache").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    let (alice_ticket, _alice) = user_ticket_and_id(&store, "alice").await;
    let (bob_ticket, bob) = user_ticket_and_id(&store, "bob").await;
    let state = support::app::state(store.clone());
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let _bob_ws = connect(addr, &bob_ticket).await;
    let join = || Event::VoiceParticipantJoined {
        channel_id: channel,
        user_id: bob,
    };

    // The stored value alone changed: the connected user's cached choice is authoritative.
    store
        .set_presence_visibility(bob, Visibility::Hidden)
        .await
        .unwrap();
    state.hub.publish(join());
    assert!(
        joined_frame(&mut alice_ws, Duration::from_secs(3))
            .await
            .is_some(),
        "the cached Online choice should have let the join through"
    );

    // A choice made through the tracker, as the visibility endpoint does, hides it at once.
    state.hub.presence().set_visibility(bob, Visibility::Hidden);
    state.hub.publish(join());
    assert!(
        joined_frame(&mut alice_ws, Duration::from_millis(600))
            .await
            .is_none(),
        "a hidden participant's join must be withheld"
    );
}
