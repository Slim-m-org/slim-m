// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space default for strong noise suppression: off on a fresh Space, set
//! by a server manager in Space settings, and readable by every client on
//! `/version` because each member's own device applies it.

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
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-strong-ns").await;
    let (admin, _) = register(&store, "root").await;
    let (member, _) = register(&store, "nia").await;
    World {
        router: app(store),
        admin,
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

    async fn set(&self, token: &str, enabled: bool) -> (StatusCode, Value) {
        self.call(
            "PATCH",
            "/space/settings",
            Some(token),
            Some(json!({"strong_noise_suppression": enabled})),
        )
        .await
    }
}

#[tokio::test]
async fn a_fresh_space_defaults_to_standard_suppression() {
    let w = world().await;
    let (_, version) = w.call("GET", "/version", None, None).await;
    assert_eq!(version["strong_noise_suppression"], false);
    let (_, settings) = w.call("GET", "/space/settings", Some(&w.admin), None).await;
    assert_eq!(settings["strong_noise_suppression"], false);
}

#[tokio::test]
async fn a_manager_turns_it_on_and_every_client_sees_it_on_version() {
    let w = world().await;
    let (status, body) = w.set(&w.admin, true).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["strong_noise_suppression"], true);

    let (_, version) = w.call("GET", "/version", None, None).await;
    assert_eq!(version["strong_noise_suppression"], true);

    let (status, body) = w.set(&w.admin, false).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["strong_noise_suppression"], false);
}

#[tokio::test]
async fn only_a_server_manager_changes_it() {
    let w = world().await;
    let (status, _) = w.set(&w.member, true).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (_, version) = w.call("GET", "/version", None, None).await;
    assert_eq!(version["strong_noise_suppression"], false);
}

#[tokio::test]
async fn setting_it_alone_leaves_the_other_settings_as_they_were() {
    let w = world().await;
    let (_, before) = w.call("GET", "/space/settings", Some(&w.admin), None).await;
    w.set(&w.admin, true).await;
    let (_, after) = w.call("GET", "/space/settings", Some(&w.admin), None).await;
    for field in ["name", "join_policy", "totp_policy", "description"] {
        assert_eq!(before[field], after[field], "{field}");
    }
}
