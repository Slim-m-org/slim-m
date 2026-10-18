// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `DELETE /members/{id}/removal` publishes `Event::MemberRestored`, the
//! mirror of the `MemberRemoved` its `PUT` sibling already publishes:
//! without it a remove-then-restore left the member invisible in every
//! already-open client until an unrelated refetch (the 2026-08-11 review's
//! M1). The `dm_open_publishes_no_event.rs` shape: subscribe to the hub
//! directly around the real route.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::hub::{Event, Hub};
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

fn app_with_hub(store: Store, hub: Hub) -> Router {
    support::app::builder(store).hub(hub).router()
}

async fn restore(app: &Router, admin_token: &str, target: &str) -> StatusCode {
    app.clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/members/{target}/removal"))
                .header("authorization", format!("Bearer {admin_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn restoring_a_removed_member_publishes_member_restored() {
    let (store, _guard) = support::new_store("slimm-member-restored").await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());

    let admin = store.create_account("admin", "Admin", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let admin_tokens = store.open_session(admin.id, "cli").await.unwrap();
    let bob = store.create_account("bob", "Bob", "x").await.unwrap();
    store
        .remove_from_space(bob.id, admin.id, Some("spam"))
        .await
        .unwrap();

    let mut rx = hub.subscribe();
    let status = restore(&app, &admin_tokens.access_token, &bob.id.to_string()).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let mut restored = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event.into_inner(), Event::MemberRestored(id) if id == bob.id) {
            restored = true;
        }
    }
    assert!(restored, "a real restore must publish MemberRestored");
}

/// The 404 path is a no-op and must say nothing: a frame for a member who
/// was never removed would make every client refetch a roster that did not
/// change.
#[tokio::test]
async fn a_restore_of_an_unremoved_member_publishes_nothing() {
    let (store, _guard) = support::new_store("slimm-member-restored").await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());

    let admin = store.create_account("admin", "Admin", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let admin_tokens = store.open_session(admin.id, "cli").await.unwrap();
    let bob = store.create_account("bob", "Bob", "x").await.unwrap();

    let mut rx = hub.subscribe();
    let status = restore(&app, &admin_tokens.access_token, &bob.id.to_string()).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(
        rx.try_recv().is_err(),
        "a no-op restore must not publish anything"
    );
}
