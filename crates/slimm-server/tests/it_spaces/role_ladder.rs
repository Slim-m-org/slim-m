// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The role ladder on every route that changes roles: a manager reaches only roles strictly below
//! their own highest, only the Space owner reaches all of them, and bots' roles follow their bots.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::{app, call_as, register_token_id as register};

const NOT_BELOW: &str = "you can only manage roles below your highest role";

/// alice claimed the Space, so owns it; bob holds `manager`, ordered admin > senior > manager > junior.
struct Ladder {
    app: Router,
    alice: String,
    alice_id: String,
    bob: (String, String),
    carol: String,
    dave: (String, String),
    admin: String,
    senior: String,
    manager: String,
    junior: String,
    _guard: support::TestDbGuard,
}

async fn ok(app: &Router, token: &str, method: &str, uri: &str, body: Option<Value>) -> Value {
    let (status, body) = call_as(app, method, uri, token, body).await;
    assert!(status.is_success(), "{method} {uri}: {status} {body}");
    body
}

async fn create(app: &Router, token: &str, name: &str, permissions: Permissions) -> String {
    let body = json!({ "name": name, "permissions": permissions.bits() });
    let role = ok(app, token, "POST", "/roles", Some(body)).await;
    role["id"].as_str().unwrap().to_owned()
}

fn member_role(user: &str, role: &str) -> String {
    format!("/members/{user}/roles/{role}")
}

async fn ladder() -> Ladder {
    let (store, guard) = support::new_store("slimm-role-ladder").await;
    let app = app(store.clone());
    let (alice, alice_id) = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let (_, carol) = register(&store, "carol").await;
    let dave = register(&store, "dave").await;
    let managing = Permissions::MANAGE_ROLES.union(Permissions::CREATE_INVITE);
    let senior = create(&app, &alice, "senior", Permissions::from_bits(0)).await;
    let manager = create(&app, &alice, "manager", managing).await;
    let junior = create(&app, &alice, "junior", Permissions::from_bits(0)).await;
    let roles = ok(&app, &alice, "GET", "/roles", None).await;
    let admin = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["name"] == "admin")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let order = json!({ "role_ids": [&admin, &senior, &manager, &junior] });
    ok(&app, &alice, "PATCH", "/roles/reorder", Some(order)).await;
    ok(&app, &alice, "PUT", &member_role(&bob.1, &manager), None).await;
    Ladder {
        app,
        alice,
        alice_id,
        bob,
        carol,
        dave,
        admin,
        senior,
        manager,
        junior,
        _guard: guard,
    }
}

impl Ladder {
    async fn as_bob(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        call_as(&self.app, method, uri, &self.bob.0, body).await
    }

    async fn refused(&self, method: &str, uri: &str, body: Option<Value>) {
        let (status, body) = self.as_bob(method, uri, body).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{method} {uri}: {body}");
        assert_eq!(body["error"], NOT_BELOW, "{method} {uri}");
        assert_eq!(body["code"], "role_hierarchy", "{method} {uri}");
    }

    async fn holds(&self, user: &str, role: &str) -> bool {
        let profile = ok(
            &self.app,
            &self.alice,
            "GET",
            &format!("/users/{user}"),
            None,
        )
        .await;
        profile["role_ids"]
            .as_array()
            .unwrap()
            .iter()
            .any(|id| id == role)
    }
}

#[tokio::test]
async fn a_manager_grants_revokes_edits_and_deletes_a_role_below_their_own() {
    let l = ladder().await;
    let grant = member_role(&l.carol, &l.junior);
    assert_eq!(
        l.as_bob("PUT", &grant, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        l.as_bob("DELETE", &grant, None).await.0,
        StatusCode::NO_CONTENT
    );
    let role = format!("/roles/{}", l.junior);
    assert_eq!(
        l.as_bob("PATCH", &role, Some(json!({ "color": 4 })))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        l.as_bob("DELETE", &role, None).await.0,
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn a_role_level_with_the_managers_highest_is_out_of_reach() {
    let l = ladder().await;
    l.refused("PUT", &member_role(&l.carol, &l.manager), None)
        .await;
    let role = format!("/roles/{}", l.manager);
    l.refused("PATCH", &role, Some(json!({ "name": "boss" })))
        .await;
    l.refused("DELETE", &role, None).await;
}

#[tokio::test]
async fn a_role_above_the_manager_is_out_of_reach_for_every_verb() {
    let l = ladder().await;
    ok(
        &l.app,
        &l.alice,
        "PUT",
        &member_role(&l.carol, &l.senior),
        None,
    )
    .await;
    l.refused("PUT", &member_role(&l.bob.1, &l.senior), None)
        .await;
    l.refused("DELETE", &member_role(&l.carol, &l.senior), None)
        .await;
    let role = format!("/roles/{}", l.senior);
    l.refused("PATCH", &role, Some(json!({ "color": 1 }))).await;
    l.refused("DELETE", &role, None).await;
    let order = json!({ "role_ids": [&l.admin, &l.manager, &l.senior, &l.junior] });
    l.refused("PATCH", "/roles/reorder", Some(order)).await;
    l.refused("POST", "/invites", Some(json!({ "role_grant": &l.senior })))
        .await;
    assert!(l.holds(&l.carol, &l.senior).await);
}

#[tokio::test]
async fn an_invite_may_grant_a_role_below_the_inviter() {
    let l = ladder().await;
    let (status, body) = l
        .as_bob("POST", "/invites", Some(json!({ "role_grant": &l.junior })))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn the_owner_reaches_the_top_role_itself_and_may_drop_it() {
    let l = ladder().await;
    ok(
        &l.app,
        &l.alice,
        "PUT",
        &member_role(&l.carol, &l.admin),
        None,
    )
    .await;
    let role = format!("/roles/{}", l.admin);
    ok(
        &l.app,
        &l.alice,
        "PATCH",
        &role,
        Some(json!({ "color": 0 })),
    )
    .await;
    let me = ok(&l.app, &l.alice, "GET", "/me", None).await;
    assert_eq!(me["is_owner"], true);
    ok(
        &l.app,
        &l.alice,
        "DELETE",
        &member_role(&l.alice_id, &l.admin),
        None,
    )
    .await;
    assert!(!l.holds(&l.alice_id, &l.admin).await);
}

/// Administrators follow the ladder like everyone else; only the owner stands above it.
#[tokio::test]
async fn an_administrator_who_is_not_the_owner_cannot_touch_the_top_role() {
    let l = ladder().await;
    ok(
        &l.app,
        &l.alice,
        "PUT",
        &member_role(&l.dave.1, &l.admin),
        None,
    )
    .await;
    let dave = &l.dave.0;
    for (method, uri, body) in [
        ("PUT", member_role(&l.carol, &l.admin), None),
        (
            "PATCH",
            format!("/roles/{}", l.admin),
            Some(json!({ "color": 2 })),
        ),
        ("DELETE", member_role(&l.dave.1, &l.admin), None),
    ] {
        let (status, body) = call_as(&l.app, method, &uri, dave, body).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{method} {uri}: {body}");
        assert_eq!(body["code"], "role_hierarchy", "{method} {uri}");
    }
    let me = ok(&l.app, dave, "GET", "/me", None).await;
    assert_eq!(me["is_owner"], false);
    let (status, _) = call_as(&l.app, "PUT", &member_role(&l.carol, &l.senior), dave, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

/// A role below the manager is still the owner's, so the manager cannot take it away from them.
#[tokio::test]
async fn nobody_but_the_owner_gives_or_takes_the_owners_roles() {
    let l = ladder().await;
    ok(
        &l.app,
        &l.alice,
        "PUT",
        &member_role(&l.alice_id, &l.junior),
        None,
    )
    .await;
    let (status, body) = l
        .as_bob("DELETE", &member_role(&l.alice_id, &l.junior), None)
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "role_hierarchy");
    assert!(l.holds(&l.alice_id, &l.junior).await);
    let (status, body) = l
        .as_bob("PUT", &member_role(&l.alice_id, &l.junior), None)
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "role_hierarchy");
}

#[tokio::test]
async fn a_manager_adds_and_removes_their_own_roles_below_their_highest() {
    let l = ladder().await;
    let own = member_role(&l.bob.1, &l.junior);
    assert_eq!(l.as_bob("PUT", &own, None).await.0, StatusCode::NO_CONTENT);
    assert!(l.holds(&l.bob.1, &l.junior).await);
    assert_eq!(
        l.as_bob("DELETE", &own, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert!(!l.holds(&l.bob.1, &l.junior).await);
}

#[tokio::test]
async fn a_manager_cannot_drop_their_own_highest_role() {
    let l = ladder().await;
    l.refused("DELETE", &member_role(&l.bob.1, &l.manager), None)
        .await;
    assert!(l.holds(&l.bob.1, &l.manager).await);
}

#[tokio::test]
async fn a_bots_roles_follow_the_bot_even_for_the_owner() {
    let l = ladder().await;
    let created = json!({ "username": "helper", "permissions": Permissions::SEND_MESSAGES.bits() });
    let bot = ok(&l.app, &l.alice, "POST", "/bots", Some(created)).await;
    let bot_id = bot["bot"]["user_id"].as_str().unwrap().to_owned();
    let roles = ok(&l.app, &l.alice, "GET", "/roles", None).await;
    let bots_roles: Vec<String> = roles
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["managed_bot_id"] == bot_id.as_str() || r["is_bots_role"] == true)
        .map(|r| r["id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(bots_roles.len(), 2, "{roles}");
    for role in &bots_roles {
        for (method, user) in [("PUT", &l.carol), ("DELETE", &bot_id)] {
            let uri = member_role(user, role);
            let (status, body) = call_as(&l.app, method, &uri, &l.alice, None).await;
            assert_eq!(status, StatusCode::CONFLICT, "{method} {uri}: {body}");
            assert_eq!(body["code"], "role_follows_bot");
        }
        let invite = json!({ "role_grant": role });
        let (status, _) = call_as(&l.app, "POST", "/invites", &l.alice, Some(invite)).await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert!(l.holds(&bot_id, role).await);
    }
    let own = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["managed_bot_id"] == bot_id.as_str())
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(&l.app, &l.alice, "DELETE", &format!("/roles/{own}"), None).await;
    assert!(!l.holds(&bot_id, &own).await);
}
