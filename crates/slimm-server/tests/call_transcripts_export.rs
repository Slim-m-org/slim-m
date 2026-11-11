// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member's export carries the call lines they spoke and nobody else's, and
//! deleting the account removes them (decision 0113).

use slimm_server::ids::{CallTranscriptId, ChannelId, UserId};
use slimm_server::store::{NewTranscript, TranscriptionMode};

mod support;
use support::app::general_channel_id;
use support::exports::{account, world};

#[tokio::test]
async fn a_member_export_holds_only_the_lines_that_member_spoke() {
    let (store, _guard) = support::new_store("slimm-transcript-export").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    let (_, bob_id) = account(&store, "bob").await;
    let (alice_id, bob_id) = (
        UserId(alice_id.parse().unwrap()),
        UserId(bob_id.parse().unwrap()),
    );
    let channel = ChannelId(general_channel_id(&store).await.parse().unwrap());
    let id = CallTranscriptId::generate();
    let new = NewTranscript {
        id,
        channel_id: channel,
        started_at: 10,
        mode: TranscriptionMode::Always,
        started_by: None,
    };
    store.begin_call_transcript(&new).await.unwrap();
    for (who, text) in [(alice_id, "alice speaks"), (bob_id, "bob speaks")] {
        store
            .append_call_transcript_line(id, who, 20, text)
            .await
            .unwrap();
    }

    let archive = w.archive(&alice, "member").await;
    let lines = archive.lines("transcript_lines.jsonl");
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0]["text"], "alice speaks");
    assert!(!archive.contains("bob speaks"));
}
