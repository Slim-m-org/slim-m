// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A block the sender cannot see (decision 0121 step 8): nothing reaches the sharer, and
//! the sender's answers and socket are the same as for a delivery.

use axum::http::StatusCode;
use serde_json::json;

use super::{KIND, PARTY, rig};
use crate::support::ws::{QUIET_WINDOW, assert_no_frame_of_type, wait_for_frame};

#[tokio::test]
async fn a_blocked_sender_is_answered_as_if_it_worked_and_nothing_reaches_the_sharer() {
    let rig = rig().await;
    rig.consent(true, true);
    rig.store
        .block_user(rig.sharer.id, rig.viewer.id)
        .await
        .unwrap();
    let mut sharer_ws = rig.socket(&rig.sharer).await;
    let png = rig.viewer_png(b"blocked").await;

    let (picture, _) = rig.stamp(&rig.viewer.token, rig.picture(&png)).await;
    let (emoji, _) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;

    assert_eq!(
        (picture, emoji),
        (StatusCode::NO_CONTENT, StatusCode::NO_CONTENT)
    );
    assert_no_frame_of_type(&mut sharer_ws, KIND).await;
    assert_eq!(rig.count("SELECT COUNT(*) FROM screen_stamps").await, 0);
    assert_eq!(
        rig.fetch_status(&rig.sharer.token, &png).await,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn the_senders_socket_hears_the_same_whether_or_not_the_sharer_blocked_them() {
    let mut heard = Vec::new();
    for blocked in [false, true] {
        let rig = rig().await;
        rig.consent(true, true);
        if blocked {
            rig.store
                .block_user(rig.sharer.id, rig.viewer.id)
                .await
                .unwrap();
        }
        let mut sharer_ws = rig.socket(&rig.sharer).await;
        let mut viewer_ws = rig.socket(&rig.viewer).await;

        let (status, error) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{error}");

        let delivered = wait_for_frame(&mut sharer_ws, KIND, QUIET_WINDOW).await;
        assert_eq!(delivered.is_some(), !blocked, "blocked: {blocked}");
        heard.push(wait_for_frame(&mut viewer_ws, KIND, QUIET_WINDOW).await);
    }

    assert_eq!(
        heard,
        vec![None, None],
        "the sender's own stamp never echoes"
    );
}

/// What the viewer is answered for a picture, then its id under another picture, then its id as an emoji.
async fn answers_to_a_reused_id(blocked: bool) -> Vec<StatusCode> {
    let rig = rig().await;
    rig.consent(true, true);
    if blocked {
        rig.store
            .block_user(rig.sharer.id, rig.viewer.id)
            .await
            .unwrap();
    }
    let first = rig.viewer_png(b"first").await;
    let second = rig.viewer_png(b"second").await;
    let body = rig.picture(&first);
    let mut other_picture = body.clone();
    other_picture["attachment_id"] = json!(second);
    let mut as_emoji = rig.emoji(PARTY);
    as_emoji["id"] = body["id"].clone();

    let mut answers = Vec::new();
    for attempt in [body, other_picture, as_emoji] {
        answers.push(rig.stamp(&rig.viewer.token, attempt).await.0);
    }
    answers
}

#[tokio::test]
async fn a_reused_id_is_answered_the_same_whether_or_not_the_sharer_blocked_the_sender() {
    let unblocked = answers_to_a_reused_id(false).await;
    let blocked = answers_to_a_reused_id(true).await;

    assert_eq!(unblocked, blocked);
    assert_eq!(blocked, vec![StatusCode::NO_CONTENT; 3]);
}
