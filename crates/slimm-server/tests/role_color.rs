// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Role.color` over `PATCH /roles/{roleId}`: a palette index a role manager
//! sets, carried on every role read, and refused outside the palette.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, new_store, register, request};

struct World {
    router: Router,
    admin: String,
    member: String,
    role_id: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-role-color").await;
    let (admin, _) = register(&store, "root").await;
    let (member, _) = register(&store, "nia").await;
    let router = app(store);
    let created = call(
        &router,
        "POST",
        "/roles",
        &admin,
        json!({"name": "mods", "permissions": 0}),
    )
    .await;
    assert_eq!(created.0, StatusCode::OK, "{}", created.1);
    World {
        role_id: created.1["id"].as_str().unwrap().to_owned(),
        router,
        admin,
        member,
        _guard: guard,
    }
}

async fn call(
    router: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Value,
) -> (StatusCode, Value) {
    let body = (method != "GET").then_some(body);
    let response = router
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

impl World {
    async fn set_color(&self, token: &str, color: Value) -> (StatusCode, Value) {
        let uri = format!("/roles/{}", self.role_id);
        call(&self.router, "PATCH", &uri, token, json!({"color": color})).await
    }

    async fn listed_color(&self) -> Value {
        let (_, roles) = call(&self.router, "GET", "/roles", &self.admin, Value::Null).await;
        roles
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == self.role_id.as_str())
            .unwrap()["color"]
            .clone()
    }
}

#[tokio::test]
async fn a_new_role_has_no_colour_until_one_is_set() {
    let w = world().await;
    assert_eq!(w.listed_color().await, Value::Null);

    let (status, body) = w.set_color(&w.admin, json!(7)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["color"], 7);
    assert_eq!(w.listed_color().await, 7);
}

#[tokio::test]
async fn setting_the_colour_leaves_the_other_fields_alone() {
    let w = world().await;
    let uri = format!("/roles/{}", w.role_id);
    call(
        &w.router,
        "PATCH",
        &uri,
        &w.admin,
        json!({"hoist": true, "mentionable": true}),
    )
    .await;
    let (_, body) = w.set_color(&w.admin, json!(2)).await;
    assert_eq!(body["hoist"], true);
    assert_eq!(body["mentionable"], true);
    assert_eq!(body["name"], "mods");
}

#[tokio::test]
async fn a_colour_outside_the_palette_is_refused() {
    let w = world().await;
    for bad in [json!(-1), json!(10), json!(1_000_000)] {
        let (status, _) = w.set_color(&w.admin, bad.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
    }
    let (status, _) = w.set_color(&w.admin, json!(9)).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn only_a_role_manager_sets_a_colour() {
    let w = world().await;
    let (status, _) = w.set_color(&w.member, json!(3)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(w.listed_color().await, Value::Null);
}
