// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A group call rings every other participant.

use axum::http::StatusCode;

use slimm_server::hub::Event;

use crate::rig::*;

#[tokio::test]
async fn a_call_rings_everyone_else_and_ends_only_when_the_last_declines() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let mut events = h.hub.subscribe();
    assert_eq!(ring(&h, &channel, &a).await, StatusCode::OK);

    assert!(incoming(&h, &a).await.is_empty(), "the caller is not rung");
    assert_eq!(incoming(&h, &b).await.len(), 1);
    assert_eq!(incoming(&h, &c).await.len(), 1);

    decline(&h, &channel, &b).await;
    assert!(incoming(&h, &b).await.is_empty());
    assert_eq!(incoming(&h, &c).await.len(), 1, "still ringing carol");
    let ended_early = std::iter::from_fn(|| events.try_recv().ok())
        .any(|e| matches!(e, Event::CallRingEnded { .. }));
    assert!(!ended_early, "one decline must not end the group's ring");

    decline(&h, &channel, &c).await;
    assert!(incoming(&h, &c).await.is_empty());
    let ended = std::iter::from_fn(|| events.try_recv().ok())
        .any(|e| matches!(e, Event::CallRingEnded { .. }));
    assert!(ended, "the last decline ends the ring");
}

#[tokio::test]
async fn only_a_participant_can_ring_a_group() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c, d) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    assert_eq!(ring(&h, &channel, &d).await, StatusCode::FORBIDDEN);
    assert!(incoming(&h, &b).await.is_empty());
}
