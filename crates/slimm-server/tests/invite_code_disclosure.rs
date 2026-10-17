// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A registration invite code is a credential, so who may read one back off a
//! member list is a privilege question, not a display question.
//!
//! Split from `tests/invites.rs`, which is at its file-budget entry and covers
//! issuing, spending and expiry. This holds the disclosure side: `redeem` needs
//! nothing but a session and applies the invite's `role_grant` to whoever
//! spends it, so a caller who could not grant that role must not be handed a
//! still-live code for it.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

/// An admin who claimed the deployment, and a plain member, both with sessions.
async fn fixture() -> (Store, Router, String, String, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-invite-disclosure").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let admin = store.create_account("admin", "Admin", &hash).await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let member = store
        .create_account("member", "Member", &hash)
        .await
        .unwrap();
    let admin_session = store.open_session(admin.id, "d").await.unwrap();
    let member_session = store.open_session(member.id, "d").await.unwrap();
    let app = app(store.clone());
    (
        store,
        app,
        admin_session.access_token,
        member_session.access_token,
        guard,
    )
}

/// Grants `bits` to the ordinary member, so a test holds exactly the
/// permissions it is about and nothing else.
async fn grant_member(store: &Store, bits: Permissions) {
    let member = store.find_credentials("member").await.unwrap().unwrap().0;
    let role = store.create_role("granted", bits, false).await.unwrap();
    store.assign_role(member, role).await.unwrap();
}

/// A registration code is a credential, not a label: `redeem` hands its
/// `role_grant` to whoever spends it. `GET /members` used to attach the raw
/// code for any BAN_MEMBERS holder, so a moderator who could not grant a
/// role could read the code off the list and take it. The ban-evasion
/// signal now needs MANAGE_ROLES, the permission that could grant it anyway.
#[tokio::test]
async fn a_moderator_without_manage_roles_cannot_read_a_registration_code() {
    let (store, app, admin, member, _guard) = fixture().await;
    grant_member(&store, Permissions::BAN_MEMBERS).await;

    let role = store
        .create_role("elevated", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    let created = app
        .clone()
        .oneshot(request(
            "POST",
            "/invites",
            Some(&admin),
            Some(json!({ "role_grant": role.to_string() })),
        ))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    let code = json_body(created).await["code"]
        .as_str()
        .unwrap()
        .to_owned();

    let registered = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(json!({
                "username": "carol",
                "display_name": "Carol",
                "password": "hunter2hunter2",
                "device_name": "cli",
                "invite_code": code,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(registered.status(), StatusCode::OK);

    let listed = app
        .clone()
        .oneshot(request("GET", "/members", Some(&member), None))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);
    let members = json_body(listed).await;
    let carol = members
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["username"] == "carol")
        .expect("carol is listed");
    assert!(
        carol["invite_code"].is_null(),
        "BAN_MEMBERS alone must not see the code, which is redeemable for {role}"
    );

    // The signal is not lost: whoever could grant the role still sees it.
    let as_admin = app
        .oneshot(request("GET", "/members", Some(&admin), None))
        .await
        .unwrap();
    let members = json_body(as_admin).await;
    let carol = members
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["username"] == "carol")
        .unwrap();
    assert_eq!(carol["invite_code"].as_str(), Some(code.as_str()));
}
