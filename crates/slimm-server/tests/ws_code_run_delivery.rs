// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `code_run.changed` and `code_runs.cleared` reach a member who can view the
//! channel and never one denied it.

use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket_and_id};

async fn frame_of_type(ws: &mut Client, kind: &str, wait: Duration) -> Option<Value> {
    tokio::time::timeout(wait, async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == kind {
                return frame;
            }
        }
    })
    .await
    .ok()
}

#[tokio::test]
async fn code_run_frames_reach_a_viewer_and_skip_a_member_denied_the_channel() {
    let (store, _guard) = support::new_store("slimm-ws-code-run-delivery").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;
    store
        .set_member_overwrite(
            channel,
            bob_id,
            Permissions::VIEW_CHANNEL,
            Permissions::NONE,
        )
        .await
        .unwrap();
    let (carol_ticket, carol_id) = user_ticket_and_id(&store, "carol").await;
    store
        .set_member_overwrite(
            channel,
            carol_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let message = MessageId::generate();
    state.hub.publish(Event::CodeRunChanged {
        channel_id: channel,
        message_id: message,
        block_index: 2,
        module_id: "runner".into(),
        command: "python".into(),
        ok: true,
        output: Arc::from("hi\n"),
        ran_by: Some(alice_id),
        ran_at: 42,
    });
    state.hub.publish(Event::CodeRunsCleared {
        channel_id: channel,
        message_id: message,
    });

    let wait = Duration::from_secs(10);
    for ws in [&mut alice_ws, &mut bob_ws] {
        let changed = frame_of_type(ws, "code_run.changed", wait)
            .await
            .expect("a viewer hears the run");
        assert_eq!(changed["channel_id"], channel.to_string());
        assert_eq!(changed["message_id"], message.to_string());
        assert_eq!(changed["block_index"], 2);
        assert_eq!(changed["output"], "hi\n");
        assert_eq!(changed["ran_by"], alice_id.to_string());
        let cleared = frame_of_type(ws, "code_runs.cleared", wait)
            .await
            .expect("a viewer hears the clear");
        assert_eq!(cleared["message_id"], message.to_string());
    }

    let short = Duration::from_millis(500);
    assert!(
        frame_of_type(&mut carol_ws, "code_run.changed", short)
            .await
            .is_none()
    );
    assert!(
        frame_of_type(&mut carol_ws, "code_runs.cleared", short)
            .await
            .is_none()
    );
}
