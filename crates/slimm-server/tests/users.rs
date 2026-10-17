// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Public user profiles, the batch lookup, and the member list: the narrow
//! public shape, consistent answers for a deleted account, and bounded
//! batches.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

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
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store.
///
/// Deliberately not the `/auth/register` route: joining a claimed deployment
/// is an invite-gated policy decision, and it is pinned by its own tests in
/// `registration_gate.rs`. These tests only need somebody signed in, so going
/// through the store keeps them independent of that policy.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    // The first account through here claims the deployment, exactly as the
    // first real registration does; later ones find it already set up.
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

#[tokio::test]
async fn a_profile_carries_only_the_public_shape() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (token, alice_id) = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/users/{alice_id}"),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;

    assert_eq!(body["id"], alice_id);
    assert_eq!(body["username"], "alice");
    assert_eq!(body["display_name"], "alice");
    assert!(body["created_at"].is_i64());
    // Nothing from the auth tables leaks onto the wire.
    assert!(body.get("password_hash").is_none());
    assert!(body.get("email").is_none());
}

/// A deleted account answers exactly like an id that was never used: 404
/// either way, so this cannot be used to confirm someone deleted their
/// account.
#[tokio::test]
async fn a_deleted_account_looks_like_one_that_never_existed() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (token, _my_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    let never_existed = Uuid::now_v7().to_string();

    let missing_status = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/users/{never_existed}"),
            Some(&token),
            None,
        ))
        .await
        .unwrap()
        .status();

    let bob_user_id = slimm_server::ids::UserId(Uuid::parse_str(&bob_id).unwrap());
    store.delete_account(bob_user_id).await.unwrap();

    let deleted_status = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/users/{bob_id}"),
            Some(&token),
            None,
        ))
        .await
        .unwrap()
        .status();

    assert_eq!(missing_status, StatusCode::NOT_FOUND);
    assert_eq!(deleted_status, missing_status);
}

#[tokio::test]
async fn batch_lookup_skips_ids_with_nothing_to_report() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (token, alice_id) = register(&store, "alice").await;
    let (_, bob_id) = register(&store, "bob").await;
    let never_existed = Uuid::now_v7().to_string();

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/users?ids={alice_id},{bob_id},{never_existed}"),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let ids: Vec<&str> = body
        .as_array()
        .unwrap()
        .iter()
        .map(|u| u["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids.len(), 2, "the never-existed id is simply absent");
    assert!(ids.contains(&alice_id.as_str()));
    assert!(ids.contains(&bob_id.as_str()));
}

#[tokio::test]
async fn an_empty_batch_returns_an_empty_list() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request("GET", "/users", Some(&token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body.as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn a_batch_over_the_cap_is_rejected() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let ids: Vec<String> = (0..101).map(|_| Uuid::now_v7().to_string()).collect();
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/users?ids={}", ids.join(",")),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn an_unparseable_id_in_the_batch_is_a_bad_request() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request("GET", "/users?ids=not-a-uuid", Some(&token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn the_member_list_is_paginated_and_bounded() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (token, first_id) = register(&store, "alice").await;
    let (_, second_id) = register(&store, "bob").await;
    let (_, third_id) = register(&store, "carol").await;

    let first_page = json_body(
        app.clone()
            .oneshot(request("GET", "/members?limit=2", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let first_page = first_page.as_array().unwrap();
    assert_eq!(first_page.len(), 2);
    assert_eq!(first_page[0]["id"], first_id);
    assert_eq!(first_page[1]["id"], second_id);

    let cursor = first_page[1]["id"].as_str().unwrap();
    let second_page = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/members?after={cursor}&limit=2"),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let second_page = second_page.as_array().unwrap();
    assert_eq!(second_page.len(), 1);
    assert_eq!(second_page[0]["id"], third_id);
}

#[tokio::test]
async fn the_member_list_requires_authentication() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());

    let response = app
        .clone()
        .oneshot(request("GET", "/members", None, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

/// A moderator's whole reason for wanting this: spotting a returning,
/// ban-evading account by the invite it came in through. Absent (not just
/// null) for the caller's own entry, since `register` claims the deployment
/// through `create_account` directly rather than an invite; see MOD9.
#[tokio::test]
async fn a_ban_members_caller_sees_the_invite_code_a_member_registered_through() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let admin_user_id = slimm_server::ids::UserId(Uuid::parse_str(&admin_id).unwrap());

    let invite = store
        .create_invite(admin_user_id, None, None, None)
        .await
        .unwrap();
    let joiner = store
        .register_account("bob", "Bob", "not-a-real-hash", Some(&invite.code))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            "/members?limit=10",
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let entries = body.as_array().unwrap();

    let bob_entry = entries
        .iter()
        .find(|u| u["id"] == joiner.id.to_string())
        .expect("bob is in the member list");
    assert_eq!(bob_entry["invite_code"], invite.code);

    let admin_entry = entries
        .iter()
        .find(|u| u["id"] == admin_id)
        .expect("admin is in the member list");
    assert!(
        admin_entry["invite_code"].is_null(),
        "the admin claimed the deployment directly, with no invite behind it"
    );
}

/// Two members through two different invites: a moderator must see each
/// member's own code, never the other's. The lookup is keyed by id, not by
/// list position, and this fails loudly if that ever regresses to positional.
#[tokio::test]
async fn each_member_shows_its_own_invite_not_another_members() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let admin_user_id = slimm_server::ids::UserId(Uuid::parse_str(&admin_id).unwrap());

    let invite_bob = store
        .create_invite(admin_user_id, None, None, None)
        .await
        .unwrap();
    let bob = store
        .register_account("bob", "Bob", "not-a-real-hash", Some(&invite_bob.code))
        .await
        .unwrap();
    let invite_carol = store
        .create_invite(admin_user_id, None, None, None)
        .await
        .unwrap();
    let carol = store
        .register_account(
            "carol",
            "Carol",
            "not-a-real-hash",
            Some(&invite_carol.code),
        )
        .await
        .unwrap();
    assert_ne!(
        invite_bob.code, invite_carol.code,
        "the two invites must differ for this test to prove anything"
    );

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            "/members?limit=10",
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let entries = body.as_array().unwrap();

    let bob_entry = entries
        .iter()
        .find(|u| u["id"] == bob.id.to_string())
        .expect("bob is listed");
    assert_eq!(bob_entry["invite_code"], invite_bob.code);
    let carol_entry = entries
        .iter()
        .find(|u| u["id"] == carol.id.to_string())
        .expect("carol is listed");
    assert_eq!(carol_entry["invite_code"], invite_carol.code);
}

/// The invite code is a moderation signal, not a public one: a caller
/// without BAN_MEMBERS must not see the field at all, not even as null.
#[tokio::test]
async fn a_non_moderator_does_not_see_the_invite_code_field() {
    let (store, _guard) = support::new_store("slimm-users-test").await;
    let app = app(store.clone());
    let (_admin_token, admin_id) = register(&store, "alice").await;
    let admin_user_id = slimm_server::ids::UserId(Uuid::parse_str(&admin_id).unwrap());

    let invite = store
        .create_invite(admin_user_id, None, None, None)
        .await
        .unwrap();
    store
        .register_account("bob", "Bob", "not-a-real-hash", Some(&invite.code))
        .await
        .unwrap();

    let plain = store
        .create_account("carol", "Carol", "not-a-real-hash")
        .await
        .unwrap();
    assert!(
        !store
            .base_permissions(plain.id)
            .await
            .unwrap()
            .contains(Permissions::BAN_MEMBERS),
        "carol must not hold BAN_MEMBERS for this test to prove anything"
    );
    let plain_token = store
        .open_session(plain.id, "cli")
        .await
        .unwrap()
        .access_token;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            "/members?limit=10",
            Some(&plain_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    for entry in body.as_array().unwrap() {
        assert!(
            entry.get("invite_code").is_none(),
            "invite_code must be absent, not null, for a non-moderator caller: {entry}"
        );
    }
}
