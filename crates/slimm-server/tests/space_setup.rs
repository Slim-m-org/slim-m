// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The first-run setup: the capacity report is admin-only, only the admin who
//! claimed the deployment can close the offer, and closing it is audited.

use axum::http::StatusCode;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

mod support;

use support::app::{app, call, register_account};

async fn second_admin(store: &Store) -> String {
    let user = store.create_user("co-admin", "Co-admin").await.unwrap();
    let role = store
        .create_role("also-admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(user.id, role).await.unwrap();
    store
        .open_session(user.id, "laptop")
        .await
        .unwrap()
        .access_token
}

#[tokio::test]
async fn the_claiming_admin_is_offered_setup_and_sees_this_machine() {
    let (store, _guard) = support::new_store("slimm-space-setup-read").await;
    let claimer = register_account(&store, "root").await;
    let router = app(store);

    let (status, body) = call(&router, "GET", "/space/setup", Some(&claimer.token), None).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["claimed_by_me"], true);
    assert_eq!(body["completed"], false);
    let capacity = &body["capacity"];
    assert!(capacity["cores"].as_u64().unwrap() >= 1);
    assert!(capacity["disk_free_bytes"].as_u64().unwrap() > 0);
    let estimate = &capacity["estimate"];
    assert!(estimate["members_min"].as_u64() < estimate["members_max"].as_u64());
    assert!(estimate["voice_min"].is_null(), "voice is not configured");
}

#[tokio::test]
async fn a_member_gets_neither_the_report_nor_a_way_to_close_the_offer() {
    let (store, _guard) = support::new_store("slimm-space-setup-member").await;
    register_account(&store, "root").await;
    let member = register_account(&store, "nia").await;
    let router = app(store);

    let (read, _) = call(&router, "GET", "/space/setup", Some(&member.token), None).await;
    let (close, _) = call(
        &router,
        "POST",
        "/space/setup/complete",
        Some(&member.token),
        None,
    )
    .await;
    let (anonymous, _) = call(&router, "GET", "/space/setup", None, None).await;

    assert_eq!(read, StatusCode::FORBIDDEN);
    assert_eq!(close, StatusCode::FORBIDDEN);
    assert_eq!(anonymous, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn another_admin_is_not_offered_setup_and_cannot_close_it_for_the_claimer() {
    let (store, _guard) = support::new_store("slimm-space-setup-other-admin").await;
    let claimer = register_account(&store, "root").await;
    let other = second_admin(&store).await;
    let router = app(store);

    let (_, seen) = call(&router, "GET", "/space/setup", Some(&other), None).await;
    let (close, _) = call(&router, "POST", "/space/setup/complete", Some(&other), None).await;
    let (_, still_owed) = call(&router, "GET", "/space/setup", Some(&claimer.token), None).await;

    assert_eq!(seen["claimed_by_me"], false);
    assert_eq!(close, StatusCode::FORBIDDEN);
    assert_eq!(still_owed["completed"], false);
}

#[tokio::test]
async fn closing_the_offer_sticks_is_repeatable_and_lands_in_the_audit_log() {
    let (store, _guard) = support::new_store("slimm-space-setup-complete").await;
    let claimer = register_account(&store, "root").await;
    let router = app(store.clone());

    let (first, _) = call(
        &router,
        "POST",
        "/space/setup/complete",
        Some(&claimer.token),
        None,
    )
    .await;
    let done_at = store.space_setup().await.unwrap().done_at;
    let (second, _) = call(
        &router,
        "POST",
        "/space/setup/complete",
        Some(&claimer.token),
        None,
    )
    .await;

    assert_eq!(
        (first, second),
        (StatusCode::NO_CONTENT, StatusCode::NO_CONTENT)
    );
    assert_eq!(store.space_setup().await.unwrap().done_at, done_at);
    let (_, body) = call(&router, "GET", "/space/setup", Some(&claimer.token), None).await;
    assert_eq!(body["completed"], true);
    let (_, log) = call(
        &router,
        "GET",
        "/space/audit-log",
        Some(&claimer.token),
        None,
    )
    .await;
    let actions: Vec<&str> = log
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|entry| entry["action"].as_str())
        .collect();
    assert!(actions.contains(&"space.setup_complete"), "{actions:?}");
}
