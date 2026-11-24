// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Event ids stay distinct when events of one kind arrive in the same millisecond.

use std::collections::HashSet;

use slimm_server::http::spawn_module_events;
use slimm_server::hub::{Event, MessageEvent};
use slimm_server::ids::MessageId;

use crate::support;
use support::module_events_world::EventModule;
use support::module_world::world;
use support::wait::wait_for;
use support::wasm_fixtures::event_recorder_wasm;

#[tokio::test]
async fn votes_in_the_same_millisecond_get_distinct_ids() {
    let w = world("slimm-modevents-vote-ids").await;
    let _consumer = spawn_module_events(w.state.clone());
    w.install_event_module(EventModule {
        id: "listener",
        wasm: event_recorder_wasm(),
        subscribes: &["poll.voted"],
        approved: &["events", "kv.store"],
    })
    .await;
    let general = w.store.create_channel("general", "text").await.unwrap();
    let message = MessageId::generate();
    for _ in 0..20 {
        w.hub.publish(Event::Message(MessageEvent::PollVoted {
            channel_id: general.id,
            message_id: message,
            options: vec![(0, 1)],
            runoff: None,
            version: 1,
            cast: None,
        }));
    }
    let seen = wait_for("every vote to be delivered", || async {
        let all = w.recorded_events("listener").await;
        (all.len() >= 20).then_some(all)
    })
    .await;
    let ids: HashSet<String> = seen
        .iter()
        .map(|e| e["id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(ids.len(), seen.len(), "every vote has its own id");
}
