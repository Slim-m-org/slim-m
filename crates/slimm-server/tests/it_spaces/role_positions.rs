// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Role positions stay distinct, so the ladder never meets a tie it was not asked for: a new
//! role, bot role or Bots role enters at the bottom, and a manager who is not the owner reorders
//! what sits below them however the numbers above them happen to lie.

use std::collections::HashSet;

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::{app, call_as, register_token_id as register};

struct Space {
    app: Router,
    alice: String,
    bob: (String, String),
    carol: (String, String),
    admin: String,
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

/// alice claimed the Space and owns it; nobody has reordered a role.
async fn space(prefix: &str) -> Space {
    let (store, guard) = support::new_store(prefix).await;
    let app = app(store.clone());
    let (alice, _) = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let carol = register(&store, "carol").await;
    let roles = ok(&app, &alice, "GET", "/roles", None).await;
    let admin = role_named(&roles, "admin");
    Space {
        app,
        alice,
        bob,
        carol,
        admin,
        _guard: guard,
    }
}

fn role_named(roles: &Value, name: &str) -> String {
    roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["name"] == name)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

impl Space {
    async fn grant(&self, user: &str, role: &str) {
        let uri = format!("/members/{user}/roles/{role}");
        ok(&self.app, &self.alice, "PUT", &uri, None).await;
    }

    async fn everyone(&self) -> String {
        let roles = ok(&self.app, &self.alice, "GET", "/roles", None).await;
        let everyone = roles
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["is_everyone"] == true);
        everyone.unwrap()["id"].as_str().unwrap().to_owned()
    }

    /// Every role but `@everyone`, top first, as the roles list shows them.
    async fn order(&self) -> Vec<(String, i64)> {
        let roles = ok(&self.app, &self.alice, "GET", "/roles", None).await;
        roles
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["is_everyone"] == false)
            .map(|r| {
                let id = r["id"].as_str().unwrap().to_owned();
                (id, r["position"].as_i64().unwrap())
            })
            .collect()
    }

    async fn reorder(&self, token: &str, ids: &[&String]) -> (StatusCode, Value) {
        let body = json!({ "role_ids": ids });
        call_as(&self.app, "PATCH", "/roles/reorder", token, Some(body)).await
    }
}

#[tokio::test]
async fn a_new_role_bot_role_and_bots_role_each_enter_at_the_bottom_untied() {
    let s = space("slimm-role-positions-distinct").await;
    let older = create(&s.app, &s.alice, "older", Permissions::NONE).await;
    let newer = create(&s.app, &s.alice, "newer", Permissions::NONE).await;
    let bot = json!({ "username": "helper", "permissions": Permissions::SEND_MESSAGES.bits() });
    ok(&s.app, &s.alice, "POST", "/bots", Some(bot)).await;

    let order = s.order().await;
    let positions: HashSet<i64> = order.iter().map(|(_, p)| *p).collect();
    assert_eq!(positions.len(), order.len(), "{order:?}");
    assert!(order.iter().all(|(_, p)| *p >= 1), "{order:?}");
    let ids: Vec<&String> = order.iter().map(|(id, _)| id).collect();
    assert_eq!(ids[..3], [&s.admin, &older, &newer], "{order:?}");
}

#[tokio::test]
async fn an_administrator_who_is_not_the_owner_reorders_below_them_on_a_fresh_space() {
    let s = space("slimm-role-positions-fresh").await;
    let mods = create(&s.app, &s.alice, "mod", Permissions::NONE).await;
    let helper = create(&s.app, &s.alice, "helper", Permissions::NONE).await;
    s.grant(&s.bob.1, &s.admin).await;

    let (status, body) = s.reorder(&s.bob.0, &[&s.admin, &helper, &mods]).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let ids: Vec<String> = s.order().await.into_iter().map(|(id, _)| id).collect();
    assert_eq!(ids, [s.admin.clone(), helper, mods]);
}

#[tokio::test]
async fn a_manager_still_reorders_below_them_after_a_role_is_created_and_one_deleted() {
    let s = space("slimm-role-positions-churn").await;
    let manager = create(&s.app, &s.alice, "manager", Permissions::MANAGE_ROLES).await;
    let a = create(&s.app, &s.alice, "a", Permissions::NONE).await;
    s.grant(&s.bob.1, &manager).await;
    let (status, body) = s.reorder(&s.alice, &[&s.admin, &manager, &a]).await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let b = create(&s.app, &s.bob.0, "b", Permissions::NONE).await;
    let (status, body) = s.reorder(&s.bob.0, &[&s.admin, &manager, &b, &a]).await;
    assert_eq!(status, StatusCode::OK, "{body}");

    ok(&s.app, &s.alice, "DELETE", &format!("/roles/{a}"), None).await;
    let c = create(&s.app, &s.alice, "c", Permissions::NONE).await;
    let (status, body) = s.reorder(&s.bob.0, &[&s.admin, &manager, &c, &b]).await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let (status, body) = s.reorder(&s.bob.0, &[&manager, &s.admin, &c, &b]).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "role_hierarchy");
    let (status, body) = s.reorder(&s.bob.0, &[&s.admin, &c, &manager, &b]).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    let ids: Vec<String> = s.order().await.into_iter().map(|(id, _)| id).collect();
    assert_eq!(ids, [s.admin.clone(), manager, c, b]);
}

/// A bot that manages roles grants one made after its own, with nobody reordering first.
#[tokio::test]
async fn a_bot_that_manages_roles_grants_a_role_made_after_its_own() {
    let s = space("slimm-role-positions-bot").await;
    let bot = json!({ "username": "roles", "permissions": 0 });
    let bot = ok(&s.app, &s.alice, "POST", "/bots", Some(bot)).await;
    let (bot_id, bot_token) = (
        bot["bot"]["user_id"].as_str().unwrap().to_owned(),
        bot["token"].as_str().unwrap().to_owned(),
    );
    let moderator = create(&s.app, &s.alice, "bot-moderator", Permissions::MANAGE_ROLES).await;
    s.grant(&bot_id, &moderator).await;
    let tester = create(&s.app, &s.alice, "tester", Permissions::NONE).await;

    let uri = format!("/members/{}/roles/{tester}", s.carol.1);
    let (status, body) = call_as(&s.app, "PUT", &uri, &bot_token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
}

/// A moderator acts on a member whose only role is newer than theirs, with nobody reordering.
#[tokio::test]
async fn a_moderator_times_out_a_member_holding_a_newer_role() {
    let s = space("slimm-role-positions-moderator").await;
    let moderating = Permissions::KICK_MEMBERS.union(Permissions::BAN_MEMBERS);
    let mods = create(&s.app, &s.alice, "mod", moderating).await;
    let member = create(&s.app, &s.alice, "member", Permissions::NONE).await;
    s.grant(&s.bob.1, &mods).await;
    s.grant(&s.carol.1, &member).await;

    let uri = format!("/members/{}/timeout", s.carol.1);
    let body = json!({ "duration_seconds": 60 });
    let (status, body) = call_as(&s.app, "PUT", &uri, &s.bob.0, Some(body)).await;
    assert!(status.is_success(), "{status} {body}");
}

/// `@everyone` sits below every real role, as it does for channel overwrites.
#[tokio::test]
async fn a_manager_at_the_bottom_still_edits_everyone() {
    let s = space("slimm-role-positions-everyone").await;
    create(&s.app, &s.alice, "older", Permissions::NONE).await;
    let manager = create(&s.app, &s.alice, "manager", Permissions::MANAGE_ROLES).await;
    s.grant(&s.bob.1, &manager).await;
    let everyone = s.everyone().await;

    let uri = format!("/roles/{everyone}");
    let body = json!({ "color": 1 });
    let (status, body) = call_as(&s.app, "PATCH", &uri, &s.bob.0, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

/// Managing roles through `@everyone` alone is no role of your own to make one below.
#[tokio::test]
async fn a_new_role_needs_a_role_of_your_own() {
    let s = space("slimm-role-positions-create").await;
    let bottom = create(&s.app, &s.alice, "bottom", Permissions::MANAGE_ROLES).await;
    s.grant(&s.bob.1, &bottom).await;
    let fresh = json!({ "name": "fresh", "permissions": 0 });
    let (status, body) = call_as(&s.app, "POST", "/roles", &s.bob.0, Some(fresh.clone())).await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let everyone = s.everyone().await;
    let open =
        json!({ "permissions": Permissions::MANAGE_ROLES.union(Permissions::VIEW_CHANNEL).bits() });
    ok(
        &s.app,
        &s.alice,
        "PATCH",
        &format!("/roles/{everyone}"),
        Some(open),
    )
    .await;
    let (status, body) = call_as(&s.app, "POST", "/roles", &s.carol.0, Some(fresh)).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "role_hierarchy");
}
