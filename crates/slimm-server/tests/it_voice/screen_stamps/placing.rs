// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Placing a stamp: the call, the consent, the canvas bar and the picture rules each
//! refuse what they should, and what passes reaches the sharer's screen once.

use axum::http::StatusCode;
use futures_util::SinkExt;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tokio_tungstenite::tungstenite::Message as WsMessage;

use super::{KIND, PARTY, read_stamp, rig};
use crate::support::ws::{assert_no_frame_of_type, read_frame_of_type, settle};

#[tokio::test]
async fn an_emoji_stamp_reaches_the_sharer_after_their_consent_says_stamps() {
    let rig = rig().await;
    let mut sharer_ws = rig.socket(&rig.sharer).await;
    sharer_ws
        .send(WsMessage::Text(
            json!({
                "type": "canvas.screen_annotation", "channel_id": rig.channel,
                "target_user_id": rig.sharer.id.to_string(), "kind": "consent",
                "allowed": true, "aspect": 1.78, "stamps": true,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let consent = read_frame_of_type(&mut sharer_ws, KIND).await;
    assert_eq!(consent["stamps"], true, "the consent relay carries stamps");
    settle(&mut sharer_ws).await;

    let body = rig.emoji(PARTY);
    let (status, error) = rig.stamp(&rig.viewer.token, body.clone()).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{error}");

    let frame = read_stamp(&mut sharer_ws).await;
    assert_eq!(frame["user_id"], rig.viewer.id.to_string());
    assert_eq!(frame["target_user_id"], rig.sharer.id.to_string());
    assert_eq!(frame["annotation_id"], body["id"]);
    assert_eq!(frame["points"], json!([0.42, 0.31]));
    assert_eq!(frame["size"], 0.12);
    assert_eq!(frame["emoji"], PARTY);
    assert_eq!(frame["ended"], true);
    assert!(frame.get("attachment").is_none() && frame.get("animated").is_none());
    assert_eq!(
        (
            rig.count("SELECT COUNT(*) FROM canvas_ops").await,
            rig.count("SELECT COUNT(*) FROM canvas_objects").await,
            rig.count("SELECT COUNT(*) FROM screen_stamps").await,
        ),
        (0, 0, 0),
        "a stamp on a share leaves nothing on the board, and an emoji is not stored"
    );
}

#[tokio::test]
async fn a_sharer_on_an_older_client_never_receives_a_stamp() {
    let rig = rig().await;
    let mut sharer_ws = rig.socket(&rig.sharer).await;
    sharer_ws
        .send(WsMessage::Text(
            json!({
                "type": "canvas.screen_annotation", "channel_id": rig.channel,
                "target_user_id": rig.sharer.id.to_string(), "kind": "consent",
                "allowed": true, "aspect": 1.78,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let consent = read_frame_of_type(&mut sharer_ws, KIND).await;
    assert!(consent.get("stamps").is_none());
    settle(&mut sharer_ws).await;

    let (status, body) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;

    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"], "Their screen is not taking stamps right now");
    assert_no_frame_of_type(&mut sharer_ws, KIND).await;
}

#[tokio::test]
async fn a_picture_stamp_names_its_attachment_and_whether_a_tile_may_animate_it() {
    let rig = rig().await;
    rig.consent(true, true);
    let mut sharer_ws = rig.socket(&rig.sharer).await;
    let png = rig.viewer_png(b"one").await;
    let gif = rig
        .upload(
            &rig.viewer.token,
            "wave.gif",
            crate::support::images::animated_gif(),
        )
        .await;

    assert_eq!(
        rig.stamp(&rig.viewer.token, rig.picture(&png)).await.0,
        StatusCode::NO_CONTENT
    );
    let still = read_stamp(&mut sharer_ws).await;
    assert_eq!(
        rig.stamp(&rig.viewer.token, rig.picture(&gif)).await.0,
        StatusCode::NO_CONTENT
    );
    let moving = read_stamp(&mut sharer_ws).await;

    assert_eq!(still["attachment"], png);
    assert!(still.get("animated").is_none() && still.get("emoji").is_none());
    assert_eq!(moving["attachment"], gif);
    assert_eq!(moving["animated"], true);
    assert_eq!(rig.count("SELECT COUNT(*) FROM screen_stamps").await, 2);
    assert_eq!(rig.count("SELECT COUNT(*) FROM canvas_ops").await, 0);
}

#[tokio::test]
async fn only_someone_in_the_call_can_stamp_a_screen_being_shared_there() {
    let rig = rig().await;
    rig.consent(true, true);

    let (outside, body) = rig.stamp(&rig.dave.token, rig.emoji(PARTY)).await;
    assert_eq!(outside, StatusCode::FORBIDDEN);
    assert_eq!(body["error"], "Join the call to stamp");

    rig.seat(&[rig.sharer.id, rig.viewer.id], &[]);
    let (not_sharing, _) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;
    rig.seat(&[rig.viewer.id], &[]);
    let (target_gone, _) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;

    assert_eq!(
        (not_sharing, target_gone),
        (StatusCode::CONFLICT, StatusCode::CONFLICT)
    );
}

#[tokio::test]
async fn the_sharers_live_consent_must_say_both_allowed_and_stamps() {
    let rig = rig().await;
    let (none, _) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;
    rig.consent(true, false);
    let (drawing_only, _) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;
    rig.consent(false, true);
    let (withdrawn, _) = rig.stamp(&rig.carol.token, rig.emoji(PARTY)).await;
    rig.consent(true, true);
    let (both, body) = rig.stamp(&rig.carol.token, rig.emoji(PARTY)).await;

    assert_eq!(
        (none, drawing_only, withdrawn),
        (
            StatusCode::CONFLICT,
            StatusCode::CONFLICT,
            StatusCode::CONFLICT
        )
    );
    assert_eq!(both, StatusCode::NO_CONTENT, "{body}");
}

#[tokio::test]
async fn stamping_takes_the_same_bar_as_ink() {
    let rig = rig().await;
    rig.consent(true, true);
    rig.store
        .set_member_overwrite(
            rig.channel_id,
            rig.viewer.id,
            Permissions::NONE,
            Permissions::USE_CANVAS,
        )
        .await
        .unwrap();
    let (no_canvas, _) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;

    let until = crate::support::totp_clock::now_ms() + 60_000;
    rig.store
        .set_member_timeout(rig.carol.id, until, None, rig.admin.id)
        .await
        .unwrap();
    let (timed_out, _) = rig.stamp(&rig.carol.token, rig.emoji(PARTY)).await;

    assert_eq!(
        (no_canvas, timed_out),
        (StatusCode::FORBIDDEN, StatusCode::FORBIDDEN)
    );
}

#[tokio::test]
async fn a_picture_also_needs_attach_files_and_must_be_a_small_image_the_sender_may_use() {
    let rig = rig().await;
    rig.consent(true, true);
    let carols = rig
        .upload(
            &rig.carol.token,
            "c.png",
            crate::support::images::png(16, 16, b"carol"),
        )
        .await;
    let text = rig
        .upload(&rig.viewer.token, "notes.txt", b"just some text".to_vec())
        .await;
    let heavy = [0x5Au8; 32];
    rig.store
        .store_attachment(
            &heavy,
            9 * 1024 * 1024,
            "image/png",
            "big.png",
            Some(rig.viewer.id),
        )
        .await
        .unwrap();
    let heavy: String = heavy.iter().map(|b| format!("{b:02x}")).collect();

    let (not_theirs, _) = rig.stamp(&rig.viewer.token, rig.picture(&carols)).await;
    let (not_a_picture, _) = rig.stamp(&rig.viewer.token, rig.picture(&text)).await;
    let (too_big, _) = rig.stamp(&rig.viewer.token, rig.picture(&heavy)).await;
    rig.store
        .set_member_overwrite(
            rig.channel_id,
            rig.carol.id,
            Permissions::NONE,
            Permissions::ATTACH_FILES,
        )
        .await
        .unwrap();
    let (no_attach, _) = rig.stamp(&rig.carol.token, rig.picture(&carols)).await;
    let (emoji_still_fine, _) = rig.stamp(&rig.carol.token, rig.emoji(PARTY)).await;

    assert_eq!(
        (
            not_theirs,
            not_a_picture,
            too_big,
            no_attach,
            emoji_still_fine
        ),
        (
            StatusCode::NOT_FOUND,
            StatusCode::BAD_REQUEST,
            StatusCode::BAD_REQUEST,
            StatusCode::FORBIDDEN,
            StatusCode::NO_CONTENT,
        )
    );
    assert_eq!(rig.count("SELECT COUNT(*) FROM screen_stamps").await, 0);
}

#[tokio::test]
async fn a_malformed_stamp_is_refused_before_anything_else() {
    let rig = rig().await;
    rig.consent(true, true);
    let mut own = rig.emoji(PARTY);
    own["target_user_id"] = json!(rig.viewer.id.to_string());
    let mut both = rig.emoji(PARTY);
    both["attachment_id"] = json!("ab".repeat(32));
    let mut off_screen = rig.emoji(PARTY);
    off_screen["x"] = json!(1.5);
    let unknown_custom = rig.emoji(&uuid::Uuid::now_v7().to_string());
    let (viewer, carol) = (&rig.viewer.token, &rig.carol.token);

    for (token, body, why) in [
        (viewer, own, "your own screen"),
        (viewer, rig.emoji("visit example.com"), "free text"),
        (viewer, both, "two contents"),
        (carol, off_screen, "off the screen"),
        (carol, unknown_custom, "an emoji this Space does not have"),
    ] {
        let (status, error) = rig.stamp(token, body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}: {error}");
    }
}

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
async fn a_replay_relays_once_and_a_reused_id_is_refused() {
    let rig = rig().await;
    rig.consent(true, true);
    let mut sharer_ws = rig.socket(&rig.sharer).await;
    let first = rig.viewer_png(b"first").await;
    let second = rig.viewer_png(b"second").await;
    let body = rig.picture(&first);

    assert_eq!(
        rig.stamp(&rig.viewer.token, body.clone()).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        rig.stamp(&rig.viewer.token, body.clone()).await.0,
        StatusCode::NO_CONTENT
    );
    read_stamp(&mut sharer_ws).await;
    settle(&mut sharer_ws).await;
    assert_no_frame_of_type(&mut sharer_ws, KIND).await;

    let mut other_picture = body.clone();
    other_picture["attachment_id"] = json!(second);
    let mut as_emoji = rig.emoji(PARTY);
    as_emoji["id"] = body["id"].clone();
    let (reused, _) = rig.stamp(&rig.viewer.token, other_picture).await;
    let (emoji_reuse, _) = rig.stamp(&rig.carol.token, as_emoji).await;
    let carols = rig
        .upload(
            &rig.carol.token,
            "c.png",
            crate::support::images::png(16, 16, b"carol"),
        )
        .await;
    let mut hijack = body.clone();
    hijack["attachment_id"] = json!(carols);
    let (carol_reuse, _) = rig.stamp(&rig.carol.token, hijack).await;

    assert_eq!(
        (reused, emoji_reuse, carol_reuse),
        (
            StatusCode::CONFLICT,
            StatusCode::CONFLICT,
            StatusCode::CONFLICT
        )
    );
    assert_eq!(rig.count("SELECT COUNT(*) FROM screen_stamps").await, 1);
}

#[tokio::test]
async fn three_stamps_at_once_then_the_rate_limit() {
    let rig = rig().await;
    rig.consent(true, true);
    let mut statuses = Vec::new();
    for _ in 0..4 {
        statuses.push(rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await.0);
    }
    let (someone_else, _) = rig.stamp(&rig.carol.token, rig.emoji(PARTY)).await;

    assert_eq!(
        statuses,
        vec![
            StatusCode::NO_CONTENT,
            StatusCode::NO_CONTENT,
            StatusCode::NO_CONTENT,
            StatusCode::TOO_MANY_REQUESTS,
        ]
    );
    assert_eq!(
        someone_else,
        StatusCode::NO_CONTENT,
        "the limit is per person"
    );
}

#[tokio::test]
async fn a_stamp_sent_over_the_socket_never_reaches_the_sharer() {
    let rig = rig().await;
    rig.consent(true, true);
    let mut sharer_ws = rig.socket(&rig.sharer).await;
    let mut viewer_ws = rig.socket(&rig.viewer).await;
    viewer_ws
        .send(WsMessage::Text(
            json!({
                "type": "canvas.screen_annotation", "channel_id": rig.channel,
                "target_user_id": rig.sharer.id.to_string(), "kind": "stamp",
                "annotation_id": uuid::Uuid::now_v7().to_string(),
                "points": [0.5, 0.5], "size": 0.3, "emoji": PARTY,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    settle(&mut viewer_ws).await;

    assert_no_frame_of_type(&mut sharer_ws, KIND).await;
}
