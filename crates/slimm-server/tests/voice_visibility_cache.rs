// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice join is gated on the joiner's chosen visibility, read from the
//! presence tracker's cache while they are connected instead of the store.

use std::time::Duration;

use slimm_server::hub::Event;
use slimm_server::permissions::Permissions;
use slimm_server::presence::Visibility;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket_and_id};

/// Every join frame that arrives before one for `until`, or `None` if that one never comes.
async fn joins_before(ws: &mut Client, until: &str, wait: Duration) -> Option<Vec<String>> {
    let deadline = tokio::time::Instant::now() + wait;
    let mut seen = Vec::new();
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        let frame = tokio::time::timeout(left, read_frame(ws)).await.ok()?;
        if frame["type"] != "voice.participant_joined" {
            continue;
        }
        let user = frame["user_id"].as_str().unwrap_or_default().to_owned();
        if user == until {
            return Some(seen);
        }
        seen.push(user);
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
    let (_carol_ticket, carol) = user_ticket_and_id(&store, "carol").await;
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
    state.hub.publish(Event::VoiceParticipantJoined {
        channel_id: channel,
        user_id: carol,
    });
    let before_carol = joins_before(&mut alice_ws, &carol.to_string(), Duration::from_secs(3))
        .await
        .expect("the sentinel join should arrive");
    assert_eq!(
        before_carol,
        vec![bob.to_string()],
        "the cached Online choice should have let the join through"
    );

    // A choice made through the tracker, as the visibility endpoint does, hides it at once.
    state.hub.presence().set_visibility(bob, Visibility::Hidden);
    state.hub.publish(join());
    // Frames reach a connection in publish order, so carol's join arriving proves bob's had its chance.
    state.hub.publish(Event::VoiceParticipantJoined {
        channel_id: channel,
        user_id: carol,
    });
    let before_carol = joins_before(&mut alice_ws, &carol.to_string(), Duration::from_secs(3))
        .await
        .expect("the sentinel join should arrive");
    assert!(
        before_carol.is_empty(),
        "a hidden participant's join must be withheld, saw {before_carol:?}"
    );
}
