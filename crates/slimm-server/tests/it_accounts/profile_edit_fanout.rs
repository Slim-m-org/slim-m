// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A profile edit is announced to every connected client, so edits are rate
//! limited on their own and an edit that changes nothing announces nothing.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::hub::{Event, Hub};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;

fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn register(store: &Store, username: &str) -> String {
    let hash = Auth::new(2)
        .unwrap()
        .hash_password("correct-horse-battery".to_owned())
        .await
        .unwrap();
    let account = store
        .create_account(username, username, &hash)
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

async fn setup() -> (axum::Router, Hub, String, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-profile-edit-fanout").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .router();
    let token = register(&store, "alice").await;
    // After `/me`, whose first read hands this unclaimed Space to alice and says so.
    app.clone()
        .oneshot(request("GET", "/me", &token, None))
        .await
        .unwrap();
    (app, hub, token, guard)
}

fn announced(events: &mut tokio::sync::broadcast::Receiver<Event>) -> usize {
    std::iter::from_fn(|| events.try_recv().ok())
        .filter(|event| matches!(event, Event::ProfileChanged(_)))
        .count()
}

#[tokio::test]
async fn an_edit_that_changes_nothing_announces_nothing() {
    let (app, hub, token, _guard) = setup().await;
    let mut events = hub.subscribe();
    let body = || Some(json!({ "status_text": "away" }));

    for _ in 0..3 {
        let response = app
            .clone()
            .oneshot(request("PATCH", "/me", &token, body()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    assert_eq!(
        announced(&mut events),
        1,
        "only the first edit changed the profile"
    );
}

#[tokio::test]
async fn clearing_an_avatar_that_is_not_set_announces_nothing() {
    let (app, hub, token, _guard) = setup().await;
    let mut events = hub.subscribe();

    for uri in ["/me/avatar", "/me/banner"] {
        let response = app
            .clone()
            .oneshot(request("DELETE", uri, &token, None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    assert_eq!(announced(&mut events), 0);
}

#[tokio::test]
async fn a_burst_of_profile_edits_is_throttled_below_the_generic_write_budget() {
    let (app, _hub, token, _guard) = setup().await;
    let mut accepted = 0;
    for i in 0..60 {
        let response = app
            .clone()
            .oneshot(request(
                "PATCH",
                "/me",
                &token,
                Some(json!({ "status_text": format!("s{i}") })),
            ))
            .await
            .unwrap();
        if response.status() == StatusCode::OK {
            accepted += 1;
        } else {
            assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        }
    }
    assert!(
        (8..=10).contains(&accepted),
        "accepted {accepted} edits in one burst"
    );
}
