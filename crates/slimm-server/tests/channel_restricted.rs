// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /channels`'s `restricted` field: true only when `@everyone` itself
//! lacks VIEW_CHANNEL, independent of whether the caller can still see the
//! channel through some other grant.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, request_bearer as request};

/// The bootstrap account: it claims the deployment (seeding `@everyone`) and
/// picks up an `admin` role carrying ADMINISTRATOR, so it can always see
/// every channel regardless of `restricted` - see `Store::bootstrap_deployment`.
async fn register_admin(store: &Store, username: &str) -> String {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

fn row<'a>(listed: &'a Value, name: &str) -> &'a Value {
    listed
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["name"] == name)
        .unwrap_or_else(|| panic!("no channel named {name} in {listed}"))
}

/// An ordinary channel reports `restricted: false`; one where `@everyone`
/// has been denied VIEW_CHANNEL reports `restricted: true` even though the
/// caller asking (an administrator, bypassing the overwrite entirely) can
/// still see it and still holds VIEW_CHANNEL in its own `permissions` bit.
#[tokio::test]
async fn restricted_reflects_everyones_own_view_not_the_callers() {
    let (store, _guard) = support::new_store("slimm-channel-restricted-test").await;
    let token = register_admin(&store, "admin").await;
    let everyone_id = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap()
        .id;

    let open = store.create_channel("open", "text").await.unwrap();
    let hidden = store.create_channel("hidden", "text").await.unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            everyone_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let app = app(store.clone());
    let listed = json_body(
        app.oneshot(request("GET", "/channels", &token))
            .await
            .unwrap(),
    )
    .await;

    assert_eq!(row(&listed, &open.name)["restricted"], json!(false));
    assert_eq!(row(&listed, &hidden.name)["restricted"], json!(true));
    // The admin bypasses the overwrite, so it still holds VIEW_CHANNEL there.
    let hidden_bits =
        Permissions::from_bits(row(&listed, &hidden.name)["permissions"].as_i64().unwrap());
    assert!(hidden_bits.contains(Permissions::VIEW_CHANNEL));
}

/// A create answers the true value, so a channel made private draws a lock at once.
#[tokio::test]
async fn restricted_is_reported_on_a_create_response() {
    let (store, _guard) = support::new_store("slimm-channel-restricted-test").await;
    let token = register_admin(&store, "admin").await;
    let app = app(store.clone());

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/channels")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "name": "second" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let created = json_body(response).await;
    assert_eq!(created["restricted"], false);
}
