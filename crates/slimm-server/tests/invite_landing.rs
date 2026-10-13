// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The invite landing card: a banner and a description an admin sets, shown to
//! someone who holds a usable code and has no account yet.
//!
//! The check route is unauthenticated, so the main thing proved here is what
//! it does not carry: no member names beyond the inviter, no channel names.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, new_store, register, request};

const PNG: [u8; 57] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10, 0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x49, 0x44, 0x41, 0x54, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0x00, 0x00, 0x00, 0x00,
];

struct World {
    router: Router,
    store: Store,
    admin: String,
    admin_id: String,
    member: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-invite-landing").await;
    let (admin, admin_id) = register(&store, "root").await;
    let (member, _) = register(&store, "nia-private-name").await;
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
    async fn raw(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> axum::response::Response {
        self.router
            .clone()
            .oneshot(request(method, uri, token, body))
            .await
            .unwrap()
    }

    async fn call(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let response = self.raw(method, uri, token, body).await;
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn upload(&self, token: &str, bytes: Vec<u8>) -> StatusCode {
        self.upload_to("/space/banner", token, bytes).await
    }

    async fn upload_to(&self, uri: &str, token: &str, bytes: Vec<u8>) -> StatusCode {
        let request = axum::http::Request::builder()
            .method("POST")
            .uri(uri)
            .header("authorization", format!("Bearer {token}"))
            .header("content-type", "application/octet-stream")
            .body(axum::body::Body::from(bytes))
            .unwrap();
        self.router.clone().oneshot(request).await.unwrap().status()
    }

    async fn invite(&self) -> String {
        let admin = UserId(self.admin_id.parse().unwrap());
        self.store
            .create_invite(admin, None, None, None)
            .await
            .unwrap()
            .code
    }
}

#[tokio::test]
async fn unauthenticated_check_carries_only_the_public_fields() {
    let w = world().await;
    let (status, _) = w
        .call(
            "POST",
            "/channels",
            Some(&w.admin),
            Some(json!({"name": "secret-plans"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    w.call(
        "PATCH",
        "/space/settings",
        Some(&w.admin),
        Some(json!({"description": "A small home server."})),
    )
    .await;
    assert_eq!(w.upload(&w.admin, PNG.to_vec()).await, StatusCode::OK);
    let icon = w.upload_to("/space/icon", &w.admin, PNG.to_vec()).await;
    assert_eq!(icon, StatusCode::OK);
    let code = w.invite().await;

    let (status, body) = w
        .call("GET", &format!("/invites/{code}/check"), None, None)
        .await;
    assert_eq!(status, StatusCode::OK);
    let mut keys: Vec<&str> = body["community"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "banner_updated_at",
            "description",
            "expires_at",
            "icon_updated_at",
            "invited_by",
            "member_count",
            "name",
            "uses_remaining"
        ]
    );
    assert_eq!(body["community"]["description"], "A small home server.");
    assert!(body["community"]["banner_updated_at"].is_i64());
    assert!(body["community"]["icon_updated_at"].is_i64());
    assert_eq!(body["community"]["member_count"], 2);
    let text = body.to_string();
    assert!(!text.contains("secret-plans"), "a channel name leaked");
    assert!(!text.contains("nia-private-name"), "a member name leaked");
}

#[tokio::test]
async fn unusable_code_still_answers_exactly_usable_false() {
    let w = world().await;
    let (status, body) = w.call("GET", "/invites/nope/check", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({"usable": false}));
}

#[tokio::test]
async fn banner_is_served_only_for_a_usable_code() {
    let w = world().await;
    let code = w.invite().await;
    let uri = format!("/invites/{code}/banner");
    assert_eq!(
        w.raw("GET", &uri, None, None).await.status(),
        StatusCode::NOT_FOUND
    );

    assert_eq!(w.upload(&w.admin, PNG.to_vec()).await, StatusCode::OK);
    let response = w.raw("GET", &uri, None, None).await;
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(bytes.as_ref(), PNG);

    let bogus = w.raw("GET", "/invites/nope/banner", None, None).await;
    assert_eq!(bogus.status(), StatusCode::NOT_FOUND);
    let unauth = w.raw("GET", "/space/banner", None, None).await;
    assert_eq!(unauth.status(), StatusCode::UNAUTHORIZED);
    let member = w.raw("GET", "/space/banner", Some(&w.member), None).await;
    assert_eq!(member.status(), StatusCode::OK);
}

#[tokio::test]
async fn only_a_server_manager_changes_the_banner_and_it_must_be_an_image() {
    let w = world().await;
    assert_eq!(
        w.upload(&w.member, PNG.to_vec()).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        w.upload(&w.admin, b"not an image".to_vec()).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        w.upload(&w.admin, Vec::new()).await,
        StatusCode::BAD_REQUEST
    );
    let mut huge = PNG.to_vec();
    huge.resize(4 * 1024 * 1024 + 1, 0);
    assert_eq!(
        w.upload(&w.admin, huge).await,
        StatusCode::PAYLOAD_TOO_LARGE
    );

    let member_delete = w
        .raw("DELETE", "/space/banner", Some(&w.member), None)
        .await;
    assert_eq!(member_delete.status(), StatusCode::FORBIDDEN);

    assert_eq!(w.upload(&w.admin, PNG.to_vec()).await, StatusCode::OK);
    let gone = w.raw("DELETE", "/space/banner", Some(&w.admin), None).await;
    assert_eq!(gone.status(), StatusCode::NO_CONTENT);
    let (_, settings) = w.call("GET", "/space/settings", Some(&w.admin), None).await;
    assert!(settings["banner_updated_at"].is_null());
    let after = w.raw("GET", "/space/banner", Some(&w.admin), None).await;
    assert_eq!(after.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn description_is_trimmed_bounded_and_manager_only() {
    let w = world().await;
    let patch = |token: &str, text: &str| {
        let body = json!({"description": text});
        let token = token.to_owned();
        async move { (token, body) }
    };
    let (t, b) = patch(&w.member, "hi").await;
    let (status, _) = w.call("PATCH", "/space/settings", Some(&t), Some(b)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (t, b) = patch(&w.admin, "  hello  ").await;
    let (status, body) = w.call("PATCH", "/space/settings", Some(&t), Some(b)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["description"], "hello");

    for bad in [
        "x".repeat(281),
        "ad\u{202E}min".to_owned(),
        "line\nbreak".to_owned(),
    ] {
        let (t, b) = patch(&w.admin, &bad).await;
        let (status, _) = w.call("PATCH", "/space/settings", Some(&t), Some(b)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad:?}");
    }
    let (t, b) = patch(&w.admin, &"x".repeat(280)).await;
    let (status, _) = w.call("PATCH", "/space/settings", Some(&t), Some(b)).await;
    assert_eq!(status, StatusCode::OK);

    let (t, b) = patch(&w.admin, "").await;
    let (_, body) = w.call("PATCH", "/space/settings", Some(&t), Some(b)).await;
    assert_eq!(body["description"], "");
}

#[tokio::test]
async fn icon_is_served_only_for_a_usable_code_and_to_members() {
    let w = world().await;
    let code = w.invite().await;
    let uri = format!("/invites/{code}/icon");
    assert_eq!(
        w.raw("GET", &uri, None, None).await.status(),
        StatusCode::NOT_FOUND
    );

    let up = w.upload_to("/space/icon", &w.admin, PNG.to_vec()).await;
    assert_eq!(up, StatusCode::OK);
    let response = w.raw("GET", &uri, None, None).await;
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(bytes.as_ref(), PNG);

    let bogus = w.raw("GET", "/invites/nope/icon", None, None).await;
    assert_eq!(bogus.status(), StatusCode::NOT_FOUND);
    let unauth = w.raw("GET", "/space/icon", None, None).await;
    assert_eq!(unauth.status(), StatusCode::UNAUTHORIZED);
    let member = w.raw("GET", "/space/icon", Some(&w.member), None).await;
    assert_eq!(member.status(), StatusCode::OK);
    let (_, settings) = w.call("GET", "/space/settings", Some(&w.admin), None).await;
    assert!(settings["icon_updated_at"].is_i64());
    assert!(settings["banner_updated_at"].is_null());
}

#[tokio::test]
async fn only_a_server_manager_changes_the_icon_and_it_must_be_a_small_image() {
    let w = world().await;
    let up = |t: String, b: Vec<u8>| {
        let w = &w;
        async move { w.upload_to("/space/icon", &t, b).await }
    };
    assert_eq!(
        up(w.member.clone(), PNG.to_vec()).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        up(w.admin.clone(), b"not an image".to_vec()).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        up(w.admin.clone(), Vec::new()).await,
        StatusCode::BAD_REQUEST
    );
    let mut huge = PNG.to_vec();
    huge.resize(512 * 1024 + 1, 0);
    assert_eq!(
        up(w.admin.clone(), huge).await,
        StatusCode::PAYLOAD_TOO_LARGE
    );

    let member_delete = w.raw("DELETE", "/space/icon", Some(&w.member), None).await;
    assert_eq!(member_delete.status(), StatusCode::FORBIDDEN);

    assert_eq!(up(w.admin.clone(), PNG.to_vec()).await, StatusCode::OK);
    let gone = w.raw("DELETE", "/space/icon", Some(&w.admin), None).await;
    assert_eq!(gone.status(), StatusCode::NO_CONTENT);
    let (_, settings) = w.call("GET", "/space/settings", Some(&w.admin), None).await;
    assert!(settings["icon_updated_at"].is_null());
    let after = w.raw("GET", "/space/icon", Some(&w.admin), None).await;
    assert_eq!(after.status(), StatusCode::NOT_FOUND);
}
