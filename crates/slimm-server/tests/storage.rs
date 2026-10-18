// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Operator-visible storage usage and sweep health: `GET /space/storage`.
//! See `docs/decisions/0008-space-analytics.md` for the MANAGE_SERVER gating
//! this route mirrors, and `store/storage.rs` for how each figure is
//! computed.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

use support::app::{app, json_body};

async fn store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn request(token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri("/space/storage")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// An administrator plus an ordinary member: MANAGE_SERVER on one, nothing
/// beyond @everyone on the other. Mirrors `tests/space_analytics.rs`.
async fn deployment(s: &Store) -> (slimm_server::store::User, slimm_server::store::User) {
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let member = s.create_user("nia", "Nia").await.unwrap();
    (admin, member)
}

#[tokio::test]
async fn reading_storage_requires_manage_server() {
    let (s, _guard) = store("slimm-storage-forbidden").await;
    let (_admin, member) = deployment(&s).await;
    let session = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(&session.access_token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn database_bytes_is_positive_on_a_freshly_migrated_database() {
    let (s, _guard) = store("slimm-storage-db-bytes").await;
    let (admin, _member) = deployment(&s).await;
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(&session.access_token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert!(body["database_bytes"].as_i64().unwrap() > 0);
}

#[tokio::test]
async fn attachment_bytes_reflects_an_uploaded_attachment() {
    let (s, _guard) = store("slimm-storage-attachment-bytes").await;
    let (admin, member) = deployment(&s).await;
    s.store_attachment(&[7; 32], 2_500, "image/png", "a.png", Some(member.id))
        .await
        .unwrap();

    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(&session.access_token))
        .await
        .unwrap();
    let body = json_body(response).await;
    assert_eq!(body["attachment_bytes"], json!(2_500));
}

/// A channel with more attachment bytes ranks first, and a DM never appears
/// at all: the same `kind != 'dm'` scope `/space/analytics`'s `channel_count`
/// uses, kept here so a heavy DM cannot leak into an operator's ranked list
/// of channels.
#[tokio::test]
async fn top_channels_ranks_the_heaviest_channel_first_and_excludes_dms() {
    let (s, _guard) = store("slimm-storage-top-channels").await;
    let (admin, member) = deployment(&s).await;
    let light = s.create_channel("light", "text").await.unwrap();
    let heavy = s.create_channel("heavy", "text").await.unwrap();
    let dm = s.open_dm(admin.id, member.id).await.unwrap();

    s.store_attachment(&[1; 32], 1_000, "image/png", "light.png", Some(member.id))
        .await
        .unwrap();
    s.send_message(NewMessage {
        attachment_ids: &[[1; 32].to_vec()],
        spoiler_ids: &[],
        ..NewMessage::plain(light.id, member.id, MessageId::generate(), "light")
    })
    .await
    .unwrap();

    s.store_attachment(&[2; 32], 9_000, "image/png", "heavy.png", Some(member.id))
        .await
        .unwrap();
    s.send_message(NewMessage {
        attachment_ids: &[[2; 32].to_vec()],
        spoiler_ids: &[],
        ..NewMessage::plain(heavy.id, member.id, MessageId::generate(), "heavy")
    })
    .await
    .unwrap();

    s.store_attachment(&[3; 32], 50_000, "image/png", "dm.png", Some(member.id))
        .await
        .unwrap();
    s.send_message(NewMessage {
        attachment_ids: &[[3; 32].to_vec()],
        spoiler_ids: &[],
        ..NewMessage::plain(dm.id, member.id, MessageId::generate(), "dm")
    })
    .await
    .unwrap();

    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(&session.access_token))
        .await
        .unwrap();
    let body = json_body(response).await;
    let top_channels = body["top_channels"].as_array().unwrap();
    assert_eq!(top_channels.len(), 2);
    assert_eq!(top_channels[0]["name"], json!("heavy"));
    assert_eq!(top_channels[0]["attachment_bytes"], json!(9_000));
    assert_eq!(top_channels[1]["name"], json!("light"));
    assert_eq!(top_channels[1]["attachment_bytes"], json!(1_000));
}

#[tokio::test]
async fn a_recorded_sweep_run_shows_up_in_sweeps() {
    let (s, _guard) = store("slimm-storage-sweeps").await;
    let (admin, _member) = deployment(&s).await;
    s.record_sweep_run("token", 3).await.unwrap();

    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(&session.access_token))
        .await
        .unwrap();
    let body = json_body(response).await;
    let sweeps = body["sweeps"].as_array().unwrap();
    assert_eq!(sweeps.len(), 1);
    assert_eq!(sweeps[0]["name"], json!("token"));
    assert_eq!(sweeps[0]["last_reclaimed"], json!(3));
    assert!(sweeps[0]["last_run_at"].as_i64().unwrap() > 0);
}
