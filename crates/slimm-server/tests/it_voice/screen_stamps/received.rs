// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The sharer's "Pictures on your screen" list: one entry per sender, so a flood from one
//! person never pushes another off it before they are reported, and one sender's pictures.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::NewScreenStamp;

use super::pictures::{open_reports, report};
use super::{Rig, rig};

pub(super) async fn senders(rig: &Rig, token: &str) -> Vec<Value> {
    let uri = "/voice/screen-stamps/received";
    let (status, body) = rig.send("GET", uri, token, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["senders"].as_array().unwrap().clone()
}

/// The attachment ids of what `sender` stamped on `token`'s screen, as listed.
async fn pictures_from(rig: &Rig, token: &str, sender: UserId) -> Vec<String> {
    let uri = format!("/voice/screen-stamps/received/{sender}");
    let (status, body) = rig.send("GET", &uri, token, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let stamps = body["stamps"].as_array().unwrap();
    stamps
        .iter()
        .map(|stamp| stamp["attachment_id"].as_str().unwrap().to_owned())
        .collect()
}

/// Stores `times` stamps of `attachment_id` from `sender` on the sharer's screen, past the
/// route's rate limit, and returns the last one's id.
async fn stamped(rig: &Rig, sender: UserId, attachment_id: &str, times: usize) -> String {
    stamped_in(rig, rig.channel_id, sender, attachment_id, times).await
}

/// [`stamped`], in the call in `channel_id`.
pub(super) async fn stamped_in(
    rig: &Rig,
    channel_id: ChannelId,
    sender: UserId,
    attachment_id: &str,
    times: usize,
) -> String {
    let sha256 = slimm_server::media::from_hex(attachment_id).unwrap();
    let mut last = None;
    for _ in 0..times {
        let id = uuid::Uuid::now_v7();
        let stamp = NewScreenStamp {
            id,
            channel_id,
            sender_id: sender,
            target_id: rig.sharer.id,
            sha256: &sha256,
        };
        rig.store.insert_screen_stamp(&stamp).await.unwrap();
        last = Some(id.to_string());
    }
    last.unwrap()
}

/// Moves every stamp so far a minute back, so the next ones are newer.
pub(super) async fn a_minute_passes(rig: &Rig) {
    sqlx::query("UPDATE screen_stamps SET created_at = created_at - 60000")
        .execute(&rig.pool)
        .await
        .unwrap();
}

/// Each sender's id, how many they sent and their latest picture, in list order.
fn rows(listed: &[Value]) -> Vec<(String, i64, String)> {
    listed
        .iter()
        .map(|sender| {
            (
                sender["sender_id"].as_str().unwrap().to_owned(),
                sender["count"].as_i64().unwrap(),
                sender["latest"]["attachment_id"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
            )
        })
        .collect()
}

#[tokio::test]
async fn a_flood_from_one_sender_never_pushes_another_off_the_list() {
    let rig = rig().await;
    let quiet = rig.viewer_png(b"quiet").await;
    let loud = rig.viewer_png(b"loud").await;
    stamped(&rig, rig.carol.id, &quiet, 1).await;
    a_minute_passes(&rig).await;
    stamped(&rig, rig.viewer.id, &loud, 150).await;

    let listed = senders(&rig, &rig.sharer.token).await;

    assert_eq!(
        rows(&listed),
        vec![
            (rig.viewer.id.to_string(), 150, loud),
            (rig.carol.id.to_string(), 1, quiet),
        ]
    );
}

#[tokio::test]
async fn each_sender_shows_their_latest_picture_and_how_many_they_sent_that_day() {
    let rig = rig().await;
    let old = rig.viewer_png(b"old").await;
    let first = rig.viewer_png(b"first").await;
    let second = rig.viewer_png(b"second").await;
    stamped(&rig, rig.viewer.id, &old, 1).await;
    rig.age_a_day().await;
    stamped(&rig, rig.viewer.id, &first, 1).await;
    a_minute_passes(&rig).await;
    stamped(&rig, rig.viewer.id, &second, 1).await;

    let listed = senders(&rig, &rig.sharer.token).await;

    assert_eq!(
        rows(&listed),
        vec![(rig.viewer.id.to_string(), 2, second.clone())]
    );
    let latest = &listed[0]["latest"];
    assert_eq!(latest["sender_id"], rig.viewer.id.to_string());
    assert_eq!(latest["channel_id"], rig.channel);
    assert_eq!(
        (listed[0]["reported"].clone(), latest["reported"].clone()),
        (json!(false), json!(false))
    );
    assert!(senders(&rig, &rig.viewer.token).await.is_empty());
    assert_eq!(
        pictures_from(&rig, &rig.sharer.token, rig.viewer.id).await,
        vec![second, first],
        "one sender's own list is newest first and holds only the last day"
    );
}

#[tokio::test]
async fn one_senders_list_holds_only_what_they_stamped_on_the_callers_screen() {
    let rig = rig().await;
    let theirs = rig.viewer_png(b"theirs").await;
    let carols = rig.viewer_png(b"carols").await;
    stamped(&rig, rig.viewer.id, &theirs, 1).await;
    stamped(&rig, rig.carol.id, &carols, 1).await;

    let (status, _) = rig
        .send(
            "GET",
            "/voice/screen-stamps/received/not-a-uuid",
            &rig.sharer.token,
            None,
        )
        .await;

    assert_eq!(
        pictures_from(&rig, &rig.sharer.token, rig.viewer.id).await,
        vec![theirs]
    );
    assert!(
        pictures_from(&rig, &rig.carol.token, rig.viewer.id)
            .await
            .is_empty(),
        "nobody else sees what was stamped on the sharer's screen"
    );
    assert!(
        pictures_from(&rig, &rig.sharer.token, rig.dave.id)
            .await
            .is_empty()
    );
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn reporting_a_sender_takes_every_picture_of_theirs_that_day() {
    let rig = rig().await;
    let pngs = [
        rig.viewer_png(b"one").await,
        rig.viewer_png(b"two").await,
        rig.viewer_png(b"three").await,
        rig.viewer_png(b"carol").await,
    ];
    stamped(&rig, rig.viewer.id, &pngs[0], 1).await;
    a_minute_passes(&rig).await;
    let latest = stamped(&rig, rig.viewer.id, &pngs[1], 1).await;
    stamped(&rig, rig.carol.id, &pngs[3], 1).await;

    let (status, filed) = report(&rig, &rig.sharer.token, &latest).await;
    assert_eq!(status, StatusCode::OK, "{filed}");
    let after_report = senders(&rig, &rig.sharer.token).await;
    let newer = stamped(&rig, rig.viewer.id, &pngs[2], 1).await;
    let after_more = senders(&rig, &rig.sharer.token).await;
    let (_, joined) = report(&rig, &rig.sharer.token, &newer).await;

    let reported = |listed: &[Value], who: UserId| {
        let row = listed
            .iter()
            .find(|s| s["sender_id"] == who.to_string())
            .unwrap();
        (row["count"].as_i64().unwrap(), row["reported"].clone())
    };
    assert_eq!(reported(&after_report, rig.viewer.id), (2, json!(true)));
    assert_eq!(
        reported(&after_report, rig.carol.id),
        (1, json!(false)),
        "a report about one sender takes nobody else's pictures"
    );
    assert_eq!(
        reported(&after_more, rig.viewer.id),
        (3, json!(false)),
        "a picture after the report can be reported again"
    );
    assert_eq!(joined["id"], filed["id"]);
    let queue = open_reports(&rig).await;
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0]["picture_ids"], json!([pngs[0], pngs[1], pngs[2]]));
}

#[tokio::test]
async fn everyone_who_stamped_that_day_is_listed_however_many_came_after() {
    let rig = rig().await;
    let png = rig.viewer_png(b"crowd").await;
    stamped(&rig, rig.viewer.id, &png, 1).await;
    a_minute_passes(&rig).await;
    for i in 0..100 {
        let user = rig
            .store
            .create_user(&format!("crowd{i}"), "Crowd")
            .await
            .unwrap();
        stamped(&rig, user.id, &png, 1).await;
    }

    let listed = senders(&rig, &rig.sharer.token).await;

    assert_eq!(listed.len(), 101);
    assert_eq!(
        listed[100]["sender_id"],
        rig.viewer.id.to_string(),
        "the first sender is still there, oldest last"
    );
}

#[tokio::test]
async fn senders_nobody_reported_yet_come_before_the_reported_ones() {
    let rig = rig().await;
    let quiet = rig.viewer_png(b"quiet").await;
    let loud = rig.viewer_png(b"loud").await;
    stamped(&rig, rig.carol.id, &quiet, 1).await;
    a_minute_passes(&rig).await;
    let latest = stamped(&rig, rig.viewer.id, &loud, 1).await;
    let (status, filed) = report(&rig, &rig.sharer.token, &latest).await;
    assert_eq!(status, StatusCode::OK, "{filed}");

    let listed = senders(&rig, &rig.sharer.token).await;

    assert_eq!(
        rows(&listed),
        vec![
            (rig.carol.id.to_string(), 1, quiet),
            (rig.viewer.id.to_string(), 1, loud),
        ]
    );
}
