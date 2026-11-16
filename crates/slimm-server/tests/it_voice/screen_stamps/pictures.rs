// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A stamped picture after it lands: who may fetch it for the day, what the sweep takes,
//! and the sharer's report, which keeps the picture as evidence until a moderator closes it.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::run_attachment_sweep_pass;

use super::{Rig, rig};

async fn placed(rig: &Rig, attachment_id: &str) -> String {
    let body = rig.picture(attachment_id);
    let (status, error) = rig.stamp(&rig.viewer.token, body.clone()).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{error}");
    body["id"].as_str().unwrap().to_owned()
}

async fn report(rig: &Rig, token: &str, stamp_id: &str) -> (StatusCode, Value) {
    let body = json!({
        "id": uuid::Uuid::now_v7().to_string(),
        "subject_kind": "screen_stamp",
        "subject_id": stamp_id,
        "reason": "not on my desktop",
    });
    rig.send("POST", "/reports", token, Some(body)).await
}

async fn open_reports(rig: &Rig) -> Vec<Value> {
    let (status, body) = rig.send("GET", "/reports", &rig.admin.token, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body.as_array().unwrap().clone()
}

async fn file_exists(rig: &Rig, hex: &str) -> bool {
    rig.state.media.read_attachment(hex).await.is_ok()
}

#[tokio::test]
async fn the_sharer_and_the_call_can_fetch_a_stamped_picture_for_a_day() {
    let rig = rig().await;
    rig.consent(true, true);
    let png = rig.viewer_png(b"grant").await;
    let before = rig.fetch_status(&rig.sharer.token, &png).await;

    placed(&rig, &png).await;
    let sharer = rig.fetch_status(&rig.sharer.token, &png).await;
    let in_call = rig.fetch_status(&rig.carol.token, &png).await;
    let outside = rig.fetch_status(&rig.dave.token, &png).await;
    let still = rig
        .fetch_status(&rig.sharer.token, &format!("{png}?w=640&still=true"))
        .await;

    assert_eq!(
        (before, sharer, in_call, outside, still),
        (
            StatusCode::NOT_FOUND,
            StatusCode::OK,
            StatusCode::OK,
            StatusCode::NOT_FOUND,
            StatusCode::OK,
        )
    );

    rig.age_a_day().await;
    assert_eq!(
        (
            rig.fetch_status(&rig.sharer.token, &png).await,
            rig.fetch_status(&rig.carol.token, &png).await,
            rig.fetch_status(&rig.viewer.token, &png).await,
        ),
        (StatusCode::NOT_FOUND, StatusCode::NOT_FOUND, StatusCode::OK),
        "the grant ends after a day, and the uploader keeps their own"
    );
}

#[tokio::test]
async fn seeing_a_stamped_picture_never_lets_anyone_post_it() {
    let rig = rig().await;
    rig.consent(true, true);
    let png = rig.viewer_png(b"no-link").await;
    placed(&rig, &png).await;
    let general = rig.store.create_channel("general", "text").await.unwrap();
    assert_eq!(
        rig.fetch_status(&rig.sharer.token, &png).await,
        StatusCode::OK
    );

    let (status, _) = rig
        .send(
            "POST",
            &format!("/channels/{}/messages", general.id),
            &rig.sharer.token,
            Some(json!({
                "id": uuid::Uuid::now_v7().to_string(),
                "content": "look at this",
                "attachment_ids": [png],
            })),
        )
        .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (uploader, _) = rig
        .send(
            "POST",
            &format!("/channels/{}/messages", general.id),
            &rig.viewer.token,
            Some(json!({
                "id": uuid::Uuid::now_v7().to_string(),
                "content": "mine to share",
                "attachment_ids": [png],
            })),
        )
        .await;
    assert_eq!(uploader, StatusCode::OK, "the uploader still may");
}

#[tokio::test]
async fn the_sweep_takes_a_day_old_stamp_and_then_its_picture() {
    let rig = rig().await;
    rig.consent(true, true);
    let old = rig.viewer_png(b"old").await;
    let fresh = rig.viewer_png(b"fresh").await;
    placed(&rig, &old).await;
    rig.age_a_day().await;
    placed(&rig, &fresh).await;

    run_attachment_sweep_pass(&rig.store, &rig.state.media).await;

    assert_eq!(rig.count("SELECT COUNT(*) FROM screen_stamps").await, 1);
    assert!(
        !file_exists(&rig, &old).await,
        "the old picture is reclaimed"
    );
    assert!(
        file_exists(&rig, &fresh).await,
        "a stamp under a day holds its picture"
    );
    let recorded: Option<i64> =
        sqlx::query_scalar("SELECT last_reclaimed FROM sweep_status WHERE name = 'screen_stamps'")
            .fetch_optional(&rig.pool)
            .await
            .unwrap();
    assert_eq!(recorded, Some(1));
}

#[tokio::test]
async fn a_reported_picture_outlives_the_day_until_its_report_closes() {
    let rig = rig().await;
    rig.consent(true, true);
    let png = rig.viewer_png(b"evidence").await;
    let stamp_id = placed(&rig, &png).await;

    let (status, filed) = report(&rig, &rig.sharer.token, &stamp_id).await;
    assert_eq!(status, StatusCode::OK, "{filed}");
    let report_id = filed["id"].as_str().unwrap().to_owned();
    rig.age_a_day().await;
    run_attachment_sweep_pass(&rig.store, &rig.state.media).await;

    assert!(
        file_exists(&rig, &png).await,
        "an open report keeps its picture"
    );
    let queue = open_reports(&rig).await;
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0]["subject_kind"], "screen_stamp");
    assert_eq!(queue[0]["subject_id"], rig.viewer.id.to_string());
    assert_eq!(queue[0]["subject_author_id"], rig.viewer.id.to_string());
    assert_eq!(queue[0]["channel_id"], rig.channel);
    assert_eq!(queue[0]["picture_ids"], json!([png]));
    assert_eq!(
        rig.fetch_status(&rig.admin.token, &png).await,
        StatusCode::OK
    );
    assert_eq!(
        rig.fetch_status(&rig.carol.token, &png).await,
        StatusCode::NOT_FOUND,
        "a member who is no moderator loses the picture after the day"
    );

    let uri = format!("/reports/{report_id}");
    let (closed, _) = rig
        .send(
            "PATCH",
            &uri,
            &rig.admin.token,
            Some(json!({"resolution": "resolved"})),
        )
        .await;
    assert_eq!(closed, StatusCode::NO_CONTENT);
    run_attachment_sweep_pass(&rig.store, &rig.state.media).await;

    assert_eq!(rig.count("SELECT COUNT(*) FROM screen_stamps").await, 0);
    assert!(
        !file_exists(&rig, &png).await,
        "a closed report lets the sweep take it"
    );
    let (_, history) = rig
        .send("GET", "/reports/history", &rig.admin.token, None)
        .await;
    let entry = &history.as_array().unwrap()[0];
    assert_eq!(entry["subject_kind"], "screen_stamp");
    assert_eq!(entry["picture_ids"], json!([]));
}

#[tokio::test]
async fn only_the_sharer_can_report_a_stamped_picture() {
    let rig = rig().await;
    rig.consent(true, true);
    let png = rig.viewer_png(b"who").await;
    let stamp_id = placed(&rig, &png).await;
    let nowhere = uuid::Uuid::now_v7().to_string();

    let (sender, _) = report(&rig, &rig.viewer.token, &stamp_id).await;
    let (watcher, _) = report(&rig, &rig.carol.token, &stamp_id).await;
    let (unknown, _) = report(&rig, &rig.sharer.token, &nowhere).await;

    assert_eq!(
        (sender, watcher, unknown),
        (
            StatusCode::NOT_FOUND,
            StatusCode::NOT_FOUND,
            StatusCode::NOT_FOUND
        )
    );
    assert!(open_reports(&rig).await.is_empty());
}

#[tokio::test]
async fn a_second_picture_from_the_same_person_joins_the_open_report() {
    let rig = rig().await;
    rig.consent(true, true);
    let first_png = rig.viewer_png(b"one").await;
    let second_png = rig.viewer_png(b"two").await;
    let first = placed(&rig, &first_png).await;
    let second = placed(&rig, &second_png).await;

    let (_, a) = report(&rig, &rig.sharer.token, &first).await;
    let (status, b) = report(&rig, &rig.sharer.token, &second).await;
    let (_, again) = report(&rig, &rig.sharer.token, &second).await;

    assert_eq!(status, StatusCode::OK, "{b}");
    assert_eq!(a["id"], b["id"]);
    assert_eq!(a["id"], again["id"]);
    let queue = open_reports(&rig).await;
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0]["picture_ids"], json!([first_png, second_png]));
}

#[tokio::test]
async fn a_replayed_report_id_answers_the_same_report() {
    let rig = rig().await;
    rig.consent(true, true);
    let png = rig.viewer_png(b"replay").await;
    let stamp_id = placed(&rig, &png).await;
    let body = json!({
        "id": uuid::Uuid::now_v7().to_string(),
        "subject_kind": "screen_stamp",
        "subject_id": stamp_id,
        "reason": "twice",
    });

    let (_, first) = rig
        .send("POST", "/reports", &rig.sharer.token, Some(body.clone()))
        .await;
    let (status, second) = rig
        .send("POST", "/reports", &rig.sharer.token, Some(body))
        .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(first["id"], second["id"]);
    assert_eq!(open_reports(&rig).await.len(), 1);
}

#[tokio::test]
async fn the_sharer_lists_the_last_days_pictures_newest_first() {
    let rig = rig().await;
    rig.consent(true, true);
    let old = rig.viewer_png(b"old").await;
    placed(&rig, &old).await;
    rig.age_a_day().await;
    let first = rig.viewer_png(b"first").await;
    let second = rig.viewer_png(b"second").await;
    let first_id = placed(&rig, &first).await;
    placed(&rig, &second).await;
    report(&rig, &rig.sharer.token, &first_id).await;

    let (status, listed) = rig
        .send(
            "GET",
            "/voice/screen-stamps/received",
            &rig.sharer.token,
            None,
        )
        .await;
    let (_, viewers) = rig
        .send(
            "GET",
            "/voice/screen-stamps/received",
            &rig.viewer.token,
            None,
        )
        .await;

    assert_eq!(status, StatusCode::OK);
    let stamps = listed["stamps"].as_array().unwrap();
    let pictures: Vec<&str> = stamps
        .iter()
        .map(|s| s["attachment_id"].as_str().unwrap())
        .collect();
    assert_eq!(pictures, vec![second.as_str(), first.as_str()]);
    assert_eq!(stamps[0]["sender_id"], rig.viewer.id.to_string());
    assert_eq!(stamps[0]["channel_id"], rig.channel);
    assert_eq!(
        (stamps[0]["reported"].clone(), stamps[1]["reported"].clone()),
        (json!(false), json!(true))
    );
    assert!(viewers["stamps"].as_array().unwrap().is_empty());
}
