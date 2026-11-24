// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How an export ends: it expires and its file goes, a restart resumes what was
//! running, and a file no job wants is swept.

use axum::http::StatusCode;
use slimm_server::export::{spawn_export_sweep, sweep_exports_once};
use slimm_server::ids::ExportId;
use slimm_server::media::Media;

use crate::support;
use support::exports::{account, world, world_with_media};

#[tokio::test]
async fn an_archive_expires_and_its_file_is_deleted() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-export-expiry").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let job = w.export(&alice, "member").await;
    let id = job["id"].as_str().unwrap().to_owned();
    assert!(w.media.export_archive_path(&id).exists());
    assert_eq!(w.download(&alice, &id).await.0, StatusCode::OK);

    sqlx::query("UPDATE data_exports SET expires_at = 1")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        w.download(&alice, &id).await.0,
        StatusCode::NOT_FOUND,
        "a lapsed archive must not download even before the sweep runs"
    );
    sweep_exports_once(&store, &w.media).await.unwrap();

    assert!(!w.media.export_archive_path(&id).exists());
    let (_, shown) = w.call("GET", &format!("/exports/{id}"), &alice, None).await;
    assert_eq!(shown["status"], "expired");
}

#[tokio::test]
async fn a_restart_resumes_what_was_queued_or_running() {
    let (store, _guard) = support::new_store("slimm-export-restart").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    let alice_user = slimm_server::ids::UserId(alice_id.parse().unwrap());
    let running = store
        .create_data_export(alice_user, slimm_server::store::ExportKind::Member)
        .await
        .unwrap();
    assert!(store.mark_export_running(running.id).await.unwrap());

    spawn_export_sweep(store.clone(), w.media.clone());

    let finished = w.finished(&alice, &running.id.to_string()).await;
    assert_eq!(finished["status"], "ready", "{finished}");
}

#[tokio::test]
async fn an_export_is_refused_when_the_volume_is_below_its_free_floor() {
    let (store, _guard) = support::new_store("slimm-export-no-room").await;
    let media = Media::for_tests().with_min_free_bytes(Some(u64::MAX / 2));
    let w = world_with_media(store.clone(), media);
    let (alice, _) = account(&store, "alice").await;

    let job = w.export(&alice, "member").await;

    assert_eq!(job["status"], "failed", "{job}");
    assert!(job["error"].as_str().unwrap().contains("not enough room"));
}

#[tokio::test]
async fn a_file_no_job_wants_is_swept() {
    let (store, _guard) = support::new_store("slimm-export-orphan").await;
    let w = world(store.clone());
    let stray = uuid::Uuid::now_v7().to_string();
    tokio::fs::write(w.media.export_archive_path(&stray), b"left behind")
        .await
        .unwrap();
    tokio::fs::create_dir_all(w.media.export_work_dir(&stray))
        .await
        .unwrap();

    sweep_exports_once(&store, &w.media).await.unwrap();

    assert!(!w.media.export_archive_path(&stray).exists());
    assert!(!w.media.export_work_dir(&stray).exists());
}

#[tokio::test]
async fn deleting_an_export_removes_the_row_and_the_file() {
    let (store, _guard) = support::new_store("slimm-export-delete").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let job = w.export(&alice, "member").await;
    let id = job["id"].as_str().unwrap();

    let (status, _) = w
        .call("DELETE", &format!("/exports/{id}"), &alice, None)
        .await;

    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(!w.media.export_archive_path(id).exists());
    assert!(
        store
            .data_export(ExportId(id.parse().unwrap()))
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn an_unfinished_export_cannot_be_downloaded() {
    let (store, _guard) = support::new_store("slimm-export-unfinished").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    let queued = store
        .create_data_export(
            slimm_server::ids::UserId(alice_id.parse().unwrap()),
            slimm_server::store::ExportKind::Member,
        )
        .await
        .unwrap();

    let (status, _) = w.download(&alice, &queued.id.to_string()).await;

    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn an_export_cut_short_twice_fails_instead_of_looping() {
    let (store, _guard) = support::new_store("slimm-export-crash-loop").await;
    let (_alice, alice_id) = account(&store, "alice").await;
    let alice_user = slimm_server::ids::UserId(alice_id.parse().unwrap());
    let job = store
        .create_data_export(alice_user, slimm_server::store::ExportKind::Member)
        .await
        .unwrap();
    assert!(store.mark_export_running(job.id).await.unwrap());

    let first = store.requeue_interrupted_exports().await.unwrap();
    assert_eq!(first.len(), 1, "the first restart resumes it");
    assert!(store.mark_export_running(job.id).await.unwrap());
    let second = store.requeue_interrupted_exports().await.unwrap();

    assert!(
        second.is_empty(),
        "a second restart must not resume it again"
    );
    let row = store.data_export(job.id).await.unwrap().unwrap();
    assert_eq!(row.status.as_str(), "failed");
}

#[tokio::test]
async fn a_restart_does_not_resume_an_export_past_the_staleness_window() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-export-stale-resume").await;
    let (_alice, alice_id) = account(&store, "alice").await;
    let alice_user = slimm_server::ids::UserId(alice_id.parse().unwrap());
    let job = store
        .create_data_export(alice_user, slimm_server::store::ExportKind::Member)
        .await
        .unwrap();
    assert!(store.mark_export_running(job.id).await.unwrap());
    sqlx::query("UPDATE data_exports SET created_at = 1")
        .execute(&pool)
        .await
        .unwrap();

    assert!(
        store
            .requeue_interrupted_exports()
            .await
            .unwrap()
            .is_empty()
    );
}
