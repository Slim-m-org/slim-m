// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How an export ends: it expires and its file goes, a restart fails what was
//! running, and a file no job wants is swept.

use axum::http::StatusCode;
use slimm_server::export::sweep_exports_once;
use slimm_server::ids::ExportId;

mod support;

use support::exports::{account, world};

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
async fn a_restart_fails_what_was_running() {
    let (store, _guard) = support::new_store("slimm-export-restart").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    let queued = store
        .create_data_export(
            slimm_server::ids::UserId(alice_id.parse().unwrap()),
            slimm_server::store::ExportKind::Member,
        )
        .await
        .unwrap();

    assert_eq!(store.fail_interrupted_exports().await.unwrap(), 1);

    let (_, shown) = w
        .call("GET", &format!("/exports/{}", queued.id), &alice, None)
        .await;
    assert_eq!(shown["status"], "failed");
    assert!(shown["error"].as_str().unwrap().contains("restarted"));
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
