// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `PUT /channels/{channelId}/overwrites` (batch): several targets'
//! allow/deny pairs applied in one request. Same checks as the single-target
//! `PUT .../overwrites/{kind}/{id}` in `overwrites.rs`, but all-or-nothing:
//! one entry failing its escalation or existence check must leave every
//! other entry in the batch untouched too.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

async fn general_channel_id(store: &Store) -> String {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.name == "general")
        .expect("bootstrap seeds a general channel")
        .id
        .to_string()
}

async fn everyone_role_id(store: &Store) -> String {
    store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .expect("bootstrap seeds @everyone")
        .id
        .to_string()
}

async fn get_overwrites(app: &Router, admin_token: &str, channel_id: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/overwrites"),
                Some(admin_token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await
}

/// Applies two targets in one request, and both land: the read-back list
/// carries both allow/deny pairs, not just the first one processed.
#[tokio::test]
async fn batch_applies_every_entry() {
    let (store, _guard) = support::new_store("slimm-overwrites-batch-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (_member_token, member_id) = register(&store, "bob").await;
    let channel_id = general_channel_id(&store).await;
    let everyone = everyone_role_id(&store).await;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites"),
            Some(&admin_token),
            Some(json!({ "overwrites": [
                { "kind": "role", "id": everyone, "allow": 0, "deny": Permissions::SEND_MESSAGES.bits() },
                { "kind": "member", "id": member_id, "allow": Permissions::SEND_MESSAGES.bits(), "deny": 0 },
            ] })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let body = get_overwrites(&app, &admin_token, &channel_id).await;
    let overwrites = body["overwrites"].as_array().unwrap();
    assert_eq!(overwrites.len(), 2, "both entries landed");
}

/// One entry in the batch asks for a bit the caller does not hold; the whole
/// request is refused, and the other, otherwise-valid entry never lands
/// either.
#[tokio::test]
async fn batch_refuses_the_whole_request_if_one_entry_escalates() {
    let (store, _guard) = support::new_store("slimm-overwrites-batch-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (member_token, member_id) = register(&store, "bob").await;
    let channel_id = general_channel_id(&store).await;
    let everyone = everyone_role_id(&store).await;

    // bob holds MANAGE_ROLES but never BAN_MEMBERS.
    let manager_role = store
        .create_role("manager", Permissions::MANAGE_ROLES, false)
        .await
        .unwrap();
    store
        .assign_role(
            slimm_server::ids::UserId(Uuid::parse_str(&member_id).unwrap()),
            manager_role,
        )
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites"),
            Some(&member_token),
            Some(json!({ "overwrites": [
                { "kind": "role", "id": everyone, "allow": 0, "deny": Permissions::SEND_MESSAGES.bits() },
                { "kind": "member", "id": member_id, "allow": Permissions::BAN_MEMBERS.bits(), "deny": 0 },
            ] })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(
        json_body(response).await["missing_permissions"],
        Permissions::BAN_MEMBERS.bits()
    );

    let body = get_overwrites(&app, &admin_token, &channel_id).await;
    let overwrites = body["overwrites"].as_array().unwrap();
    assert!(
        overwrites.is_empty(),
        "the first entry must not have landed once the second was refused"
    );
}

/// A batch naming an unknown target is refused (and applies nothing), the
/// same as the single-target route.
#[tokio::test]
async fn batch_refuses_an_unknown_target() {
    let (store, _guard) = support::new_store("slimm-overwrites-batch-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let channel_id = general_channel_id(&store).await;
    let everyone = everyone_role_id(&store).await;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites"),
            Some(&admin_token),
            Some(json!({ "overwrites": [
                { "kind": "role", "id": everyone, "allow": 0, "deny": 0 },
                { "kind": "role", "id": Uuid::now_v7().to_string(), "allow": 0, "deny": 0 },
            ] })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);

    let body = get_overwrites(&app, &admin_token, &channel_id).await;
    assert!(body["overwrites"].as_array().unwrap().is_empty());
}
