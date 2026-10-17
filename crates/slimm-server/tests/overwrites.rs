// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel permission overwrites: MANAGE_ROLES is checked in the channel
//! itself (not the deployment-wide base), a nonexistent channel is refused
//! identically to a real one the caller cannot manage, `allow` cannot grant a
//! bit the caller lacks, and a set overwrite actually changes what the
//! evaluator returns.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::overwrite_harness::{app, general_channel_id, json_body, register, request};

async fn new_store() -> (Store, support::TestDbGuard) {
    support::overwrite_harness::new_store("slimm-overwrites-test").await
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

async fn send_message(app: &Router, channel_id: &str, token: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(token),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "hi" })),
        ))
        .await
        .unwrap()
        .status()
}

// --- Existence hiding ---

/// A channel that does not exist grants MANAGE_ROLES to nobody, administrator
/// included, since `permissions_in_channel` returns nothing at all before an
/// administrator bypass is even considered. The point is that a bogus channel
/// id and a real channel the caller cannot manage must answer identically.
#[tokio::test]
async fn nonexistent_channel_refuses_identically_for_everyone() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let everyone = everyone_role_id(&store).await;

    let missing_channel = Uuid::now_v7().to_string();
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{missing_channel}/overwrites/role/{everyone}"),
            Some(&admin_token),
            Some(json!({ "allow": 0, "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "a nonexistent channel must not be distinguishable from one the caller cannot manage"
    );
}

// --- Validation ---

#[tokio::test]
async fn kind_must_be_role_or_member() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let channel_id = general_channel_id(&store).await;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/bogus/{}", Uuid::now_v7()),
            Some(&admin_token),
            Some(json!({ "allow": 0, "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn setting_an_overwrite_for_a_nonexistent_target_is_not_found() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let channel_id = general_channel_id(&store).await;

    let no_such_role = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/role/{}", Uuid::now_v7()),
            Some(&admin_token),
            Some(json!({ "allow": 0, "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(no_such_role.status(), StatusCode::NOT_FOUND);

    let no_such_member = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!(
                "/channels/{channel_id}/overwrites/member/{}",
                Uuid::now_v7()
            ),
            Some(&admin_token),
            Some(json!({ "allow": 0, "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(no_such_member.status(), StatusCode::NOT_FOUND);
}

// --- The evaluator actually honours what gets set ---

/// Denying SEND_MESSAGES for `@everyone` in a channel takes effect at once,
/// a member overwrite re-grants it to one person despite that, and clearing
/// the `@everyone` overwrite restores the default for everyone else.
#[tokio::test]
async fn set_and_clear_actually_change_what_the_evaluator_returns() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (carol_token, carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;
    let everyone = everyone_role_id(&store).await;

    assert_eq!(
        send_message(&app, &channel_id, &carol_token).await,
        StatusCode::OK,
        "SEND_MESSAGES is in the @everyone default"
    );

    let deny = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/role/{everyone}"),
            Some(&admin_token),
            Some(json!({ "allow": 0, "deny": Permissions::SEND_MESSAGES.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(deny.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        send_message(&app, &channel_id, &carol_token).await,
        StatusCode::FORBIDDEN,
        "the @everyone deny must take effect immediately"
    );

    let regrant = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/member/{carol_id}"),
            Some(&admin_token),
            Some(json!({ "allow": Permissions::SEND_MESSAGES.bits(), "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(regrant.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        send_message(&app, &channel_id, &carol_token).await,
        StatusCode::OK,
        "a member overwrite is absolute and re-grants over the role-tier deny"
    );

    let clear = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel_id}/overwrites/role/{everyone}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(clear.status(), StatusCode::NO_CONTENT);

    let (dave_token, _dave_id) = register(&store, "dave").await;
    assert_eq!(
        send_message(&app, &channel_id, &dave_token).await,
        StatusCode::OK,
        "clearing the @everyone deny restores the default for a member who never had an override"
    );
}

/// Clearing an overwrite that was never set is not an error.
#[tokio::test]
async fn clearing_an_unset_overwrite_is_idempotent() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let channel_id = general_channel_id(&store).await;
    let everyone = everyone_role_id(&store).await;

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel_id}/overwrites/role/{everyone}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

// --- Listing ---

/// The GET a blind editor never had: every overwrite on a channel, role and
/// member alike, so a change can see what it is replacing.
#[tokio::test]
async fn listing_shows_every_overwrite_set_on_the_channel() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let channel_id = general_channel_id(&store).await;
    let everyone = everyone_role_id(&store).await;

    let role_path = format!("/channels/{channel_id}/overwrites/role/{everyone}");
    let member_path = format!("/channels/{channel_id}/overwrites/member/{bob_id}");
    for (path, allow, deny) in [
        (&role_path, Permissions::ADD_REACTIONS.bits(), 0),
        (&member_path, 0, Permissions::SEND_MESSAGES.bits()),
    ] {
        let set = app
            .clone()
            .oneshot(request(
                "PUT",
                path,
                Some(&admin_token),
                Some(json!({ "allow": allow, "deny": deny })),
            ))
            .await
            .unwrap();
        assert_eq!(set.status(), StatusCode::NO_CONTENT);
    }

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/overwrites"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let list = body["overwrites"].as_array().unwrap();
    assert_eq!(list.len(), 2);

    let role = list.iter().find(|o| o["kind"] == "role").unwrap();
    assert_eq!(role["id"], everyone);
    assert_eq!(role["allow"], Permissions::ADD_REACTIONS.bits());
    assert_eq!(role["deny"], 0);

    let member = list.iter().find(|o| o["kind"] == "member").unwrap();
    assert_eq!(member["id"], bob_id);
    assert_eq!(member["allow"], 0);
    assert_eq!(member["deny"], Permissions::SEND_MESSAGES.bits());
}

/// Reading the overwrites reveals the channel's permission config, so it needs
/// the same MANAGE_ROLES-here gate that changing them does.
#[tokio::test]
async fn listing_requires_manage_roles_here() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (_admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let channel_id = general_channel_id(&store).await;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/overwrites"),
            Some(&bob_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}
