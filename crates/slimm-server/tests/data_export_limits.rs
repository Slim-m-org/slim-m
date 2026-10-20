// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What bounds exports: pacing that deleting cannot dodge, one archive kept
//! per account and kind, room on disk, and the paths a download can take.

use axum::http::StatusCode;
use slimm_server::export;
use slimm_server::ids::UserId;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::store::ExportKind;
use sqlx::SqlitePool;

mod support;

use support::exports::{World, account, upload_png, world, world_with_media};

fn user(id: &str) -> UserId {
    UserId(id.parse().unwrap())
}

/// Moves every export row out of the cooldown.
async fn age_exports(pool: &SqlitePool) {
    sqlx::query("UPDATE data_exports SET created_at = 1")
        .execute(pool)
        .await
        .unwrap();
}

async fn audit_count(w: &World, token: &str, action: &str) -> usize {
    let (_, log) = w.call("GET", "/space/audit-log", token, None).await;
    let entries = log.as_array().unwrap();
    entries.iter().filter(|e| e["action"] == action).count()
}

#[tokio::test]
async fn deleting_an_export_does_not_reset_the_cooldown() {
    let (store, _guard) = support::new_store("slimm-export-delete-cooldown").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let job = w.export(&alice, "member").await;
    let id = job["id"].as_str().unwrap();
    let (gone, _) = w
        .call("DELETE", &format!("/exports/{id}"), &alice, None)
        .await;
    assert_eq!(gone, StatusCode::NO_CONTENT);

    let (status, _) = w.start(&alice, "member").await;

    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    let (_, listed) = w.call("GET", "/exports", &alice, None).await;
    assert!(listed.as_array().unwrap().is_empty(), "{listed}");
}

#[tokio::test]
async fn a_cancelled_queued_job_never_runs() {
    let (store, _guard) = support::new_store("slimm-export-cancel-queued").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    let queued = store
        .create_data_export(user(&alice_id), ExportKind::Member)
        .await
        .unwrap();
    let (gone, _) = w
        .call("DELETE", &format!("/exports/{}", queued.id), &alice, None)
        .await;
    assert_eq!(gone, StatusCode::NO_CONTENT);

    let job = export::Job {
        id: queued.id,
        user_id: user(&alice_id),
        kind: ExportKind::Member,
    };
    export::run(store.clone(), w.media.clone(), job).await;

    assert!(!w.media.export_archive_path(&queued.id.to_string()).exists());
    assert!(!w.media.export_work_dir(&queued.id.to_string()).exists());
}

#[tokio::test]
async fn a_failed_export_counts_toward_the_cooldown() {
    let (store, _guard) = support::new_store("slimm-export-failed-cooldown").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    let queued = store
        .create_data_export(user(&alice_id), ExportKind::Member)
        .await
        .unwrap();
    store.mark_export_failed(queued.id, "boom").await.unwrap();

    let (status, _) = w.start(&alice, "member").await;

    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn a_second_export_while_one_is_queued_is_a_conflict() {
    let (store, _guard) = support::new_store("slimm-export-busy").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    store
        .create_data_export(user(&alice_id), ExportKind::Member)
        .await
        .unwrap();

    let (status, _) = w.start(&alice, "member").await;

    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_row_stuck_queued_for_hours_no_longer_blocks_the_account() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-export-stale").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    store
        .create_data_export(user(&alice_id), ExportKind::Member)
        .await
        .unwrap();
    age_exports(&pool).await;

    let (status, _) = w.start(&alice, "member").await;

    assert_eq!(status, StatusCode::ACCEPTED);
}

#[tokio::test]
async fn a_new_archive_replaces_the_account_s_older_one() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-export-replace").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let first = w.export(&alice, "member").await;
    let first_id = first["id"].as_str().unwrap().to_owned();
    age_exports(&pool).await;

    let second = w.export(&alice, "member").await;

    assert_eq!(second["status"], "ready");
    assert!(!w.media.export_archive_path(&first_id).exists());
    let (_, old) = w
        .call("GET", &format!("/exports/{first_id}"), &alice, None)
        .await;
    assert_eq!(old["status"], "expired");
    let id = second["id"].as_str().unwrap();
    assert!(w.media.export_archive_path(id).exists());
}

#[tokio::test]
async fn an_export_that_would_not_fit_is_refused_before_it_is_built() {
    let (store, _guard) = support::new_store("slimm-export-no-room").await;
    let (alice, _) = account(&store, "alice").await;
    upload_png(&world(store.clone()), &alice).await;
    let tight = Media::for_tests().with_total_ceiling(Some(1));
    let w = world_with_media(store.clone(), tight);

    let job = w.export(&alice, "space").await;

    assert_eq!(job["status"], "failed", "{job}");
    assert!(job["error"].as_str().unwrap().contains("not enough room"));
    assert!(
        !w.media
            .export_archive_path(job["id"].as_str().unwrap())
            .exists()
    );
}

#[tokio::test]
async fn a_missing_archive_file_is_not_audited_as_a_download() {
    let (store, _guard) = support::new_store("slimm-export-missing-file").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let job = w.export(&alice, "space").await;
    let id = job["id"].as_str().unwrap();
    std::fs::remove_file(w.media.export_archive_path(id)).unwrap();

    let (status, _) = w.download(&alice, id).await;

    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(audit_count(&w, &alice, "space.export_download").await, 0);
}

#[tokio::test]
async fn a_resumed_download_is_audited_once() {
    let (store, _guard) = support::new_store("slimm-export-range").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let job = w.export(&alice, "space").await;
    let id = job["id"].as_str().unwrap();

    let first = w.download_range(&alice, id, "bytes=0-99").await;
    let resumed = w.download_range(&alice, id, "bytes=100-").await;

    assert_eq!(first, StatusCode::PARTIAL_CONTENT);
    assert_eq!(resumed, StatusCode::PARTIAL_CONTENT);
    assert_eq!(audit_count(&w, &alice, "space.export_download").await, 1);
}

#[tokio::test]
async fn an_administrator_demoted_after_starting_cannot_download() {
    let (store, _guard) = support::new_store("slimm-export-demoted").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let (bob, bob_id) = account(&store, "bob").await;
    let admin = store
        .create_role("admins", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(user(&bob_id), admin).await.unwrap();
    let job = w.export(&bob, "space").await;
    let id = job["id"].as_str().unwrap();
    store.unassign_role(user(&bob_id), admin).await.unwrap();

    let (status, _) = w.download(&bob, id).await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(audit_count(&w, &alice, "space.export_download").await, 0);
}

#[tokio::test]
async fn a_bot_can_start_its_own_member_export_without_a_password() {
    let (store, _guard) = support::new_store("slimm-export-bot").await;
    let w = world(store.clone());
    let (_, alice_id) = account(&store, "alice").await;
    let bot = store
        .create_bot("helper", "Helper", Permissions::NONE, user(&alice_id))
        .await
        .unwrap();

    let (status, job) = w.start_with(&bot.token, "member", None).await;

    assert_eq!(status, StatusCode::ACCEPTED, "{job}");
    let done = w.finished(&bot.token, job["id"].as_str().unwrap()).await;
    assert_eq!(done["status"], "ready");
}
