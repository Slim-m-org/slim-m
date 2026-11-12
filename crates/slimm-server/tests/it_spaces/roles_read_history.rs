// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /roles` shows permission bits to `MANAGE_ROLES` and to the read-only
//! `VIEW_MODERATION_HISTORY`, and to nobody else.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::http::{self};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::app::json_body;
use support::ws::user_ticket;

async fn grant(store: &Store, user: UserId, name: &str, bits: Permissions) {
    let role = store.create_role(name, bits, false).await.unwrap();
    store.assign_role(user, role).await.unwrap();
}

async fn status_and_body(
    state: &slimm_server::http::AppState,
    token: &str,
) -> (StatusCode, serde_json::Value) {
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .uri("/roles")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let body = if status == StatusCode::OK {
        json_body(response).await
    } else {
        serde_json::Value::Null
    };
    (status, body)
}

#[tokio::test]
async fn only_role_managers_and_moderation_history_readers_see_role_bits() {
    let (store, _guard) = support::new_store("slimm-roles-read-history-test").await;
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = support::app::state(store.clone());

    let (plain_token, _, _) = user_ticket(&store, "plain").await;
    let (reader_token, _, reader) = user_ticket(&store, "reader").await;
    let (manager_token, _, manager) = user_ticket(&store, "manager").await;
    grant(
        &store,
        reader,
        "history",
        Permissions::VIEW_MODERATION_HISTORY,
    )
    .await;
    grant(&store, manager, "managers", Permissions::MANAGE_ROLES).await;

    let (status, _) = status_and_body(&state, &plain_token).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    for token in [&reader_token, &manager_token] {
        let (status, body) = status_and_body(&state, token).await;
        assert_eq!(status, StatusCode::OK);
        let history = body
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["name"] == "history")
            .expect("the history role is listed");
        assert_eq!(
            history["permissions"],
            Permissions::VIEW_MODERATION_HISTORY.bits()
        );
    }
}

#[tokio::test]
async fn a_history_reader_still_cannot_change_roles() {
    let (store, _guard) = support::new_store("slimm-roles-read-history-test").await;
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = support::app::state(store.clone());
    let (token, _, reader) = user_ticket(&store, "reader").await;
    grant(
        &store,
        reader,
        "history",
        Permissions::VIEW_MODERATION_HISTORY,
    )
    .await;

    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/roles")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"name":"x","permissions":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}
