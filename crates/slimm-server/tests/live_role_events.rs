// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end coverage for the `RoleChanged` and `MemberRoleChanged` events,
//! half of the 2026-07-30 audit's fan-out finding that was missing entirely
//! (`hub.publish` never appeared in `http/roles.rs`). See `live_channel_events.rs`
//! for the channel and overwrite half of the same finding.
//!
//! Both events broadcast to every connection: they carry a role's name and
//! look (what the member list already shows) but never its permission bits,
//! the only privileged part of a role. See the doc comments on `hub::Event::RoleChanged` and `hub::Event::MemberRoleChanged`.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http::{self};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::ws::{connect, read_frame_skipping_presence_timed, serve, user_ticket};

use support::app::json_body;

fn req(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => {
            builder = builder.header("content-type", "application/json");
            builder.body(Body::from(value.to_string())).unwrap()
        }
        None => builder.body(Body::empty()).unwrap(),
    }
}

/// Grants ADMINISTRATOR to a user so every test below can create, update, and
/// delete roles and assign or unassign them without wiring up every bit each
/// verb happens to need.
async fn make_admin(store: &Store, user_id: slimm_server::ids::UserId) {
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(user_id, role).await.unwrap();
}

#[tokio::test]
async fn role_changed_reaches_everyone_with_its_look_but_not_its_bits() {
    let (store, _guard) = support::new_store("slimm-live-role-events-test").await;
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let response = http::router(state.clone())
        .oneshot(req(
            "POST",
            "/roles",
            &alice_access,
            Some(json!({ "name": "editors", "permissions": Permissions::ATTACH_FILES.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let role_id = json_body(response).await["id"].as_str().unwrap().to_owned();

    // Checked on create, update and delete, each its own publish site.
    for ws in [&mut alice_ws, &mut bob_ws] {
        let frame = read_frame_skipping_presence_timed(ws).await;
        assert_eq!(frame["type"], "role.changed");
        assert!(frame["role_id"].is_string());
        assert_eq!(frame["change"], "created");
        assert_eq!(frame["name"], "editors");
        assert_eq!(frame["after"]["name"], "editors");
        assert!(frame.get("before").is_none());
        assert!(
            !frame.to_string().contains("permissions"),
            "a role's bits are gated behind MANAGE_ROLES over REST; \
             the live frame must never carry them: {frame}"
        );
    }

    let update = http::router(state.clone())
        .oneshot(req(
            "PATCH",
            &format!("/roles/{role_id}"),
            &alice_access,
            Some(json!({ "name": "editors-renamed", "color": 2, "hoist": true })),
        ))
        .await
        .unwrap();
    assert_eq!(update.status(), StatusCode::OK);
    for ws in [&mut alice_ws, &mut bob_ws] {
        let frame = read_frame_skipping_presence_timed(ws).await;
        assert_eq!(frame["type"], "role.changed");
        assert_eq!(frame["change"], "updated");
        assert_eq!(frame["before"]["name"], "editors");
        assert_eq!(frame["after"]["name"], "editors-renamed");
        assert_eq!(frame["after"]["color"], 2);
        assert_eq!(frame["before"]["hoist"], false);
        assert_eq!(frame["after"]["hoist"], true);
        assert!(!frame.to_string().contains("permissions"), "{frame}");
    }

    let delete = http::router(state.clone())
        .oneshot(req(
            "DELETE",
            &format!("/roles/{role_id}"),
            &alice_access,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(delete.status(), StatusCode::NO_CONTENT);
    for ws in [&mut alice_ws, &mut bob_ws] {
        let frame = read_frame_skipping_presence_timed(ws).await;
        assert_eq!(frame["type"], "role.changed");
        assert_eq!(frame["change"], "deleted");
        assert_eq!(frame["name"], "editors-renamed");
        assert!(frame.get("after").is_none(), "{frame}");
    }
}

#[tokio::test]
async fn member_role_changed_reaches_everyone() {
    let (store, _guard) = support::new_store("slimm-live-role-events-test").await;
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, _bob_ticket, bob) = user_ticket(&store, "bob").await;
    let (_carol_access, carol_ticket, _carol) = user_ticket(&store, "carol").await;
    make_admin(&store, alice).await;
    let perk_role = store
        .create_role("perk", Permissions::ATTACH_FILES, false)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    // An uninvolved bystander: entitled anyway since role ids are on `GET /members`.
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let uri = format!("/members/{bob}/roles/{perk_role}");
    let response = http::router(state.clone())
        .oneshot(req("PUT", &uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // Checked on both assign and unassign: each is its own publish site.
    for ws in [&mut alice_ws, &mut carol_ws] {
        let frame = read_frame_skipping_presence_timed(ws).await;
        assert_eq!(frame["type"], "member.role_changed");
        assert_eq!(frame["user_id"], bob.to_string());
        assert_eq!(frame["role_id"], perk_role.to_string());
        assert_eq!(frame["granted"], true);
        assert_eq!(frame["role_name"], "perk");
    }

    let unassign = http::router(state.clone())
        .oneshot(req("DELETE", &uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(unassign.status(), StatusCode::NO_CONTENT);
    for ws in [&mut alice_ws, &mut carol_ws] {
        let frame = read_frame_skipping_presence_timed(ws).await;
        assert_eq!(frame["type"], "member.role_changed");
        assert_eq!(frame["granted"], false);
        assert_eq!(frame["role_name"], "perk");
    }
}
