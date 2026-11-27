// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a REST-only client needs to know about itself: its roles on `/me`, its
//! resolved permissions by name, and `/members/{id}` as a profile lookup.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::{app, call_as, register_token_id};

async fn world(
    prefix: &str,
) -> (
    axum::Router,
    support::TestDbGuard,
    (String, String),
    (String, String),
) {
    let (store, guard) = support::new_store(prefix).await;
    let alice = register_token_id(&store, "alice").await;
    let bob = register_token_id(&store, "bob").await;
    (app(store), guard, alice, bob)
}

async fn give_bob_a_role(router: &axum::Router, alice: &str, bob: &str) {
    let body = json!({ "name": "helper", "permissions": Permissions::KICK_MEMBERS.bits() });
    let (status, role) = call_as(router, "POST", "/roles", alice, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{role}");
    let uri = format!("/members/{}/roles/{}", bob, role["id"].as_str().unwrap());
    let (status, out) = call_as(router, "PUT", &uri, alice, None).await;
    assert!(status.is_success(), "{out}");
}

#[tokio::test]
async fn me_carries_the_same_role_fields_as_the_users_lookup() {
    let (router, _guard, alice, bob) = world("slimm-me-roles").await;
    give_bob_a_role(&router, &alice.0, &bob.1).await;

    let (_, me) = call_as(&router, "GET", "/me", &bob.0, None).await;
    let (_, user) = call_as(&router, "GET", &format!("/users/{}", bob.1), &bob.0, None).await;
    assert_eq!(me["roles"], json!(["helper"]), "{me}");
    for field in ["roles", "role_ids", "role_colors"] {
        assert_eq!(me[field], user[field], "{field}");
    }
}

#[tokio::test]
async fn me_roles_are_empty_not_missing_without_a_role() {
    let (router, _guard, _alice, bob) = world("slimm-me-no-roles").await;
    let (_, me) = call_as(&router, "GET", "/me", &bob.0, None).await;
    for field in ["roles", "role_ids", "role_colors"] {
        assert_eq!(me[field], json!([]), "{field}");
    }
}

fn names(body: &Value) -> Vec<&str> {
    body["names"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_str().unwrap())
        .collect()
}

#[tokio::test]
async fn own_permissions_come_back_by_name_next_to_the_bitmask() {
    let (router, _guard, _alice, bob) = world("slimm-me-perms").await;
    let (_, me) = call_as(&router, "GET", "/me", &bob.0, None).await;

    let (status, body) = call_as(&router, "GET", "/me/permissions", &bob.0, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["permissions"], me["permissions"]);
    assert!(body.get("channel_id").is_none(), "{body}");
    assert!(names(&body).contains(&"send_messages"), "{body}");
    assert!(!names(&body).contains(&"administrator"), "{body}");
}

#[tokio::test]
async fn own_channel_permissions_follow_overwrites_and_hide_unviewable_channels() {
    let (router, _guard, alice, bob) = world("slimm-me-perms-chan").await;
    let (_, general) = call_as(
        &router,
        "POST",
        "/channels",
        &alice.0,
        Some(json!({ "name": "quiet" })),
    )
    .await;
    let quiet = general["id"].as_str().unwrap();
    let deny = |bits: Permissions| json!({ "allow": 0, "deny": bits.bits() });
    let uri = format!("/channels/{quiet}/overwrites/member/{}", bob.1);
    let (status, out) = call_as(
        &router,
        "PUT",
        &uri,
        &alice.0,
        Some(deny(Permissions::SEND_MESSAGES)),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{out}");

    let uri = format!("/me/permissions?channel_id={quiet}");
    let (status, body) = call_as(&router, "GET", &uri, &bob.0, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["channel_id"], quiet);
    assert!(names(&body).contains(&"view_channel"), "{body}");
    assert!(!names(&body).contains(&"send_messages"), "{body}");
    let (_, theirs) = call_as(
        &router,
        "GET",
        &format!("/channels/{quiet}/permissions"),
        &bob.0,
        None,
    )
    .await;
    assert_eq!(body["permissions"], theirs["permissions"]);

    let uri = format!("/channels/{quiet}/overwrites/member/{}", bob.1);
    call_as(
        &router,
        "PUT",
        &uri,
        &alice.0,
        Some(deny(Permissions::VIEW_CHANNEL)),
    )
    .await;
    let missing = uuid::Uuid::now_v7().to_string();
    for channel in [quiet, missing.as_str()] {
        let uri = format!("/me/permissions?channel_id={channel}");
        let (status, body) = call_as(&router, "GET", &uri, &bob.0, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["permissions"], 0, "{body}");
        assert!(names(&body).is_empty(), "{body}");
    }
    let (status, _) = call_as(
        &router,
        "GET",
        "/me/permissions?channel_id=nope",
        &bob.0,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn an_administrator_lists_every_name() {
    let (router, _guard, alice, _bob) = world("slimm-me-perms-admin").await;
    let (_, body) = call_as(&router, "GET", "/me/permissions", &alice.0, None).await;
    assert_eq!(
        names(&body).len(),
        slimm_server::permissions::names::NAMED.len()
    );
}

#[tokio::test]
async fn members_lookup_is_the_users_lookup() {
    let (router, _guard, _alice, bob) = world("slimm-members-lookup").await;
    give_bob_a_role(&router, &_alice.0, &bob.1).await;
    let (status, member) =
        call_as(&router, "GET", &format!("/members/{}", bob.1), &bob.0, None).await;
    assert_eq!(status, StatusCode::OK, "{member}");
    let (_, user) = call_as(&router, "GET", &format!("/users/{}", bob.1), &bob.0, None).await;
    assert_eq!(member, user);
    let missing = uuid::Uuid::now_v7();
    let (status, _) = call_as(&router, "GET", &format!("/members/{missing}"), &bob.0, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
