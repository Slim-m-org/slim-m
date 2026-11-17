// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `role_colors` on a profile: every member can colour a name by its highest
//! coloured role without `GET /roles`, which needs MANAGE_ROLES.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::support;
use support::overwrite_harness::{app, new_store, register, request};

struct World {
    router: Router,
    admin: String,
    /// A plain member: no MANAGE_ROLES, so `GET /roles` is closed to them.
    reader: String,
    bob: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-member-role-colors").await;
    let (admin, _) = register(&store, "root").await;
    let (reader, _) = register(&store, "nia").await;
    let (_, bob) = register(&store, "bob").await;
    World {
        router: app(store),
        admin,
        reader,
        bob,
        _guard: guard,
    }
}

impl World {
    async fn call(&self, method: &str, uri: &str, token: &str, body: Value) -> (StatusCode, Value) {
        let body = (method != "GET").then_some(body);
        let response = self
            .router
            .clone()
            .oneshot(request(method, uri, Some(token), body))
            .await
            .unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn role(&self, name: &str, color: Option<i64>) -> String {
        let (status, role) = self
            .call(
                "POST",
                "/roles",
                &self.admin,
                json!({ "name": name, "permissions": 0 }),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{role}");
        let id = role["id"].as_str().unwrap().to_owned();
        if let Some(color) = color {
            self.set_color(&id, color).await;
        }
        id
    }

    async fn set_color(&self, role_id: &str, color: i64) {
        let (status, body) = self
            .call(
                "PATCH",
                &format!("/roles/{role_id}"),
                &self.admin,
                json!({ "color": color }),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }

    async fn grant(&self, user_id: &str, role_id: &str) {
        let (status, body) = self
            .call(
                "PUT",
                &format!("/members/{user_id}/roles/{role_id}"),
                &self.admin,
                Value::Null,
            )
            .await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    }

    /// `user_id` as a plain member reads them in the member list.
    async fn listed(&self, user_id: &str) -> Value {
        let (status, members) = self
            .call("GET", "/members", &self.reader, Value::Null)
            .await;
        assert_eq!(status, StatusCode::OK, "{members}");
        members
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["id"] == user_id)
            .unwrap()
            .clone()
    }

    /// `user_id` as a plain member resolves them for a message author line.
    async fn resolved(&self, user_id: &str) -> Value {
        let (status, users) = self
            .call(
                "GET",
                &format!("/users?ids={user_id}"),
                &self.reader,
                Value::Null,
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{users}");
        users[0].clone()
    }
}

#[tokio::test]
async fn a_member_with_no_coloured_role_has_no_colour_to_wear() {
    let w = world().await;
    assert_eq!(w.listed(&w.bob).await["role_colors"], json!([]));

    let plain = w.role("Regulars", None).await;
    w.grant(&w.bob, &plain).await;

    let bob = w.listed(&w.bob).await;
    assert_eq!(bob["roles"], json!(["Regulars"]));
    assert_eq!(bob["role_colors"], json!([null]));
}

/// Positionally matched to `roles`, which come highest position first, so
/// the first non-null entry is the colour Discord's rule picks.
#[tokio::test]
async fn colours_line_up_with_roles_highest_position_first() {
    let w = world().await;
    let top = w.role("Top", None).await;
    let middle = w.role("Middle", Some(3)).await;
    let low = w.role("Low", Some(6)).await;
    for role in [&low, &top, &middle] {
        w.grant(&w.bob, role).await;
    }
    let (_, roles) = w.call("GET", "/roles", &w.admin, Value::Null).await;
    let mut order: Vec<String> = roles
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["is_everyone"] == false)
        .map(|r| r["id"].as_str().unwrap().to_owned())
        .filter(|id| ![&top, &middle, &low].contains(&id))
        .collect();
    order.extend([top.clone(), middle.clone(), low.clone()]);
    let (status, body) = w
        .call(
            "PATCH",
            "/roles/reorder",
            &w.admin,
            json!({ "role_ids": order }),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");

    for bob in [w.listed(&w.bob).await, w.resolved(&w.bob).await] {
        assert_eq!(bob["roles"], json!(["Top", "Middle", "Low"]));
        assert_eq!(bob["role_ids"], json!([top, middle, low]));
        assert_eq!(bob["role_colors"], json!([null, 3, 6]));
    }
}

#[tokio::test]
async fn a_bots_own_role_carries_its_colour_like_any_other() {
    let w = world().await;
    let (status, created) = w
        .call(
            "POST",
            "/bots",
            &w.admin,
            json!({
                "username": "tuner",
                "permissions": Permissions::SEND_MESSAGES.bits(),
            }),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    let bot_id = created["bot"]["user_id"].as_str().unwrap().to_owned();
    let managed = created["bot"]["role_id"].as_str().unwrap().to_owned();

    let before = w.listed(&bot_id).await;
    let at = before["role_ids"]
        .as_array()
        .unwrap()
        .iter()
        .position(|id| id == managed.as_str())
        .expect("the bot holds its own role");
    assert_eq!(
        before["role_colors"].as_array().unwrap().len(),
        before["roles"].as_array().unwrap().len()
    );
    assert_eq!(before["role_colors"][at], Value::Null);

    w.set_color(&managed, 8).await;
    assert_eq!(w.listed(&bot_id).await["role_colors"][at], 8);
}

#[tokio::test]
async fn a_colour_change_reaches_the_roster_and_author_lookups() {
    let w = world().await;
    let mods = w.role("Mods", Some(1)).await;
    w.grant(&w.bob, &mods).await;
    assert_eq!(w.listed(&w.bob).await["role_colors"], json!([1]));

    w.set_color(&mods, 9).await;

    assert_eq!(w.listed(&w.bob).await["role_colors"], json!([9]));
    assert_eq!(w.resolved(&w.bob).await["role_colors"], json!([9]));
    let (_, single) = w
        .call("GET", &format!("/users/{}", w.bob), &w.reader, Value::Null)
        .await;
    assert_eq!(single["role_colors"], json!([9]));
}
