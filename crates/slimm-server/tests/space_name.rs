// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Renaming the Space: an admin sets it in Space settings, and it shows on
//! `/version` and on an invite's landing card.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, new_store, register, request};

struct World {
    router: Router,
    store: Store,
    admin: String,
    admin_id: String,
    member: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-space-name").await;
    let (admin, admin_id) = register(&store, "root").await;
    let (member, _) = register(&store, "nia").await;
    World {
        router: app(store.clone()),
        store,
        admin,
        admin_id,
        member,
        _guard: guard,
    }
}

impl World {
    async fn call(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let response = self
            .router
            .clone()
            .oneshot(request(method, uri, token, body))
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

    async fn rename(&self, token: &str, name: &str) -> (StatusCode, Value) {
        self.call(
            "PATCH",
            "/space/settings",
            Some(token),
            Some(json!({"name": name})),
        )
        .await
    }
}

#[tokio::test]
async fn a_fresh_space_is_named_slim_m_and_version_keeps_the_product_name() {
    let w = world().await;
    let (_, version) = w.call("GET", "/version", None, None).await;
    assert_eq!(version["name"], "slim-m");
    assert_eq!(version["space_name"], "slim-m");
    let (_, settings) = w.call("GET", "/space/settings", Some(&w.admin), None).await;
    assert_eq!(settings["name"], "slim-m");
}

#[tokio::test]
async fn a_rename_shows_on_version_settings_and_the_invite_card() {
    let w = world().await;
    let (status, body) = w.rename(&w.admin, "  Nick's place  ").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "Nick's place");

    let (_, version) = w.call("GET", "/version", None, None).await;
    assert_eq!(version["space_name"], "Nick's place");
    assert_eq!(version["name"], "slim-m");

    let admin = UserId(w.admin_id.parse().unwrap());
    let code = w
        .store
        .create_invite(admin, None, None, None)
        .await
        .unwrap()
        .code;
    let (_, check) = w
        .call("GET", &format!("/invites/{code}/check"), None, None)
        .await;
    assert_eq!(check["community"]["name"], "Nick's place");
}

#[tokio::test]
async fn only_a_server_manager_renames_the_space() {
    let w = world().await;
    let (status, _) = w.rename(&w.member, "Mine now").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (_, version) = w.call("GET", "/version", None, None).await;
    assert_eq!(version["space_name"], "slim-m");
}

#[tokio::test]
async fn a_name_is_trimmed_non_empty_bounded_and_visible() {
    let w = world().await;
    for bad in [
        String::new(),
        "   ".to_owned(),
        "x".repeat(65),
        "ad\u{202E}min".to_owned(),
        "line\nbreak".to_owned(),
    ] {
        let (status, _) = w.rename(&w.admin, &bad).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad:?}");
    }
    let (_, version) = w.call("GET", "/version", None, None).await;
    assert_eq!(
        version["space_name"], "slim-m",
        "a refused rename wrote anyway"
    );

    let (status, body) = w.rename(&w.admin, &"x".repeat(64)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "x".repeat(64));
}

#[tokio::test]
async fn a_bad_name_leaves_the_other_fields_in_the_same_patch_unwritten() {
    let w = world().await;
    let body = json!({"name": "", "description": "should not land"});
    let (status, _) = w
        .call("PATCH", "/space/settings", Some(&w.admin), Some(body))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (_, settings) = w.call("GET", "/space/settings", Some(&w.admin), None).await;
    assert_eq!(settings["description"], "");
}
