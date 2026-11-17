// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A report about a sender whose pictures came from several channels: it reaches the
//! moderators of each, each sees only the pictures from channels they moderate, and a
//! moderator of none of them never sees or closes it.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;

use super::pictures::{open_reports, report};
use super::received::{a_minute_passes, senders, stamped_in};
use super::{Rig, rig};

/// Makes `user` a moderator everywhere except `channel`, which they cannot see.
async fn moderator_kept_out_of(rig: &Rig, user: UserId, channel: ChannelId) {
    let role = rig
        .store
        .create_role(
            &format!("moderator-{user}"),
            Permissions::MANAGE_MESSAGES,
            false,
        )
        .await
        .unwrap();
    rig.store.assign_role(user, role).await.unwrap();
    rig.store
        .set_member_overwrite(channel, user, Permissions::NONE, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();
}

/// The open queue as `token` sees it.
async fn queue_of(rig: &Rig, token: &str) -> Vec<Value> {
    let (status, body) = rig.send("GET", "/reports", token, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body.as_array().unwrap().clone()
}

#[tokio::test]
async fn a_report_across_channels_shows_each_moderator_only_the_pictures_they_may_see() {
    let rig = rig().await;
    let private = rig
        .store
        .create_channel("private", "voice")
        .await
        .unwrap()
        .id;
    moderator_kept_out_of(&rig, rig.dave.id, private).await;
    moderator_kept_out_of(&rig, rig.carol.id, rig.channel_id).await;
    let hidden = rig.viewer_png(b"hidden").await;
    let open = rig.viewer_png(b"open").await;
    stamped_in(&rig, private, rig.viewer.id, &hidden, 1).await;
    a_minute_passes(&rig).await;
    let latest = stamped_in(&rig, rig.channel_id, rig.viewer.id, &open, 1).await;

    let (status, filed) = report(&rig, &rig.sharer.token, &latest).await;

    assert_eq!(status, StatusCode::OK, "{filed}");
    let dave = queue_of(&rig, &rig.dave.token).await;
    assert_eq!(dave.len(), 1);
    assert_eq!(dave[0]["picture_ids"], json!([open]));
    assert!(
        !Value::Array(dave).to_string().contains(&hidden),
        "a moderator kept out of a channel never learns what was stamped there"
    );
    let carol = queue_of(&rig, &rig.carol.token).await;
    assert_eq!(
        carol
            .iter()
            .map(|r| r["picture_ids"].clone())
            .collect::<Vec<_>>(),
        vec![json!([hidden])],
        "the private channel's moderators see the report and its picture"
    );
    let everyone = open_reports(&rig).await;
    assert_eq!(everyone.len(), 1);
    assert_eq!(everyone[0]["picture_ids"], json!([hidden, open]));
    assert_eq!(everyone[0]["channel_id"], Value::Null);
    assert_eq!(
        senders(&rig, &rig.sharer.token).await[0]["reported"],
        json!(true)
    );
    assert_ne!(
        rig.fetch_status(&rig.dave.token, &hidden).await,
        StatusCode::OK
    );

    let uri = format!("/reports/{}", filed["id"].as_str().unwrap());
    let resolution = Some(json!({"resolution": "resolved"}));
    let (closed, _) = rig.send("PATCH", &uri, &rig.admin.token, resolution).await;
    let (_, history) = rig
        .send("GET", "/reports/history", &rig.dave.token, None)
        .await;
    assert_eq!(closed, StatusCode::NO_CONTENT);
    assert_eq!(history[0]["picture_ids"], json!([open]), "{history}");
}

#[tokio::test]
async fn a_report_from_one_channel_stays_with_that_channels_moderators() {
    let rig = rig().await;
    moderator_kept_out_of(&rig, rig.dave.id, rig.channel_id).await;
    let png = rig.viewer_png(b"one channel").await;
    let latest = stamped_in(&rig, rig.channel_id, rig.viewer.id, &png, 1).await;

    let (status, filed) = report(&rig, &rig.sharer.token, &latest).await;

    assert_eq!(status, StatusCode::OK, "{filed}");
    assert_eq!(
        open_reports(&rig).await[0]["channel_id"],
        json!(rig.channel)
    );
    assert!(queue_of(&rig, &rig.dave.token).await.is_empty());
}

/// Two private channels and a stamp from the viewer in each, reported once by the sharer.
async fn reported_in_two_private_channels(rig: &Rig) -> (ChannelId, ChannelId, String) {
    let mut channels = Vec::new();
    for name in ["first", "second"] {
        let channel = rig.store.create_channel(name, "voice").await.unwrap().id;
        let png = rig.viewer_png(name.as_bytes()).await;
        stamped_in(rig, channel, rig.viewer.id, &png, 1).await;
        a_minute_passes(rig).await;
        channels.push(channel);
    }
    let latest = rig.viewer_png(b"latest").await;
    let latest = stamped_in(rig, channels[1], rig.viewer.id, &latest, 1).await;
    let (status, filed) = report(rig, &rig.sharer.token, &latest).await;
    assert_eq!(status, StatusCode::OK, "{filed}");
    let id = filed["id"].as_str().unwrap().to_owned();
    (channels[0], channels[1], id)
}

#[tokio::test]
async fn a_moderator_of_neither_channel_never_sees_or_closes_the_report() {
    let rig = rig().await;
    let (first, second, id) = reported_in_two_private_channels(&rig).await;
    moderator_kept_out_of(&rig, rig.dave.id, first).await;
    rig.store
        .set_member_overwrite(
            second,
            rig.dave.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    assert_eq!(open_reports(&rig).await[0]["channel_id"], Value::Null);

    assert!(queue_of(&rig, &rig.dave.token).await.is_empty());
    let uri = format!("/reports/{id}");
    let dismiss = Some(json!({"resolution": "dismissed"}));
    let (status, _) = rig.send("PATCH", &uri, &rig.dave.token, dismiss).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(open_reports(&rig).await.len(), 1, "the report stays open");

    let resolution = Some(json!({"resolution": "resolved"}));
    let (closed, _) = rig.send("PATCH", &uri, &rig.admin.token, resolution).await;
    assert_eq!(closed, StatusCode::NO_CONTENT);
    let (_, history) = rig
        .send("GET", "/reports/history", &rig.dave.token, None)
        .await;
    assert!(
        !history.to_string().contains(&id),
        "nor reads it once closed: {history}"
    );
}

#[tokio::test]
async fn reporting_the_same_sender_again_keeps_the_new_reason() {
    let rig = rig().await;
    let first = rig.viewer_png(b"first").await;
    let first = stamped_in(&rig, rig.channel_id, rig.viewer.id, &first, 1).await;
    let (status, _) = report(&rig, &rig.sharer.token, &first).await;
    assert_eq!(status, StatusCode::OK);
    let second = rig.viewer_png(b"second").await;
    let second = stamped_in(&rig, rig.channel_id, rig.viewer.id, &second, 1).await;

    let body = json!({
        "id": uuid::Uuid::now_v7().to_string(),
        "subject_kind": "screen_stamp",
        "subject_id": second,
        "reason": "worse this time",
    });
    let (status, filed) = rig
        .send("POST", "/reports", &rig.sharer.token, Some(body))
        .await;

    assert_eq!(status, StatusCode::OK, "{filed}");
    let open = open_reports(&rig).await;
    assert_eq!(open.len(), 1);
    assert_eq!(open[0]["reason"], "not on my desktop\nworse this time");
}
