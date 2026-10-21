// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The "invite a friend" button asks for `reuse`, so clicking it again returns the same live
//! code instead of minting one per click, and only a dead code is replaced.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::store::Store;

mod support;

use support::app::{builder, call};
use support::overwrite_harness::{new_store, register};

struct World {
    store: Store,
    router: Router,
    admin: String,
    member: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-invite-reuse").await;
    let (admin, _) = register(&store, "root").await;
    let (member, _) = register(&store, "nia").await;
    let router = builder(store.clone()).router();
    let (status, _) = call(
        &router,
        "PATCH",
        "/space/settings",
        Some(&admin),
        Some(json!({"members_can_invite": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    World {
        router,
        store,
        admin,
        member,
        _guard: guard,
    }
}

impl World {
    async fn create(&self, token: &str, body: Value) -> String {
        let (status, invite) =
            call(&self.router, "POST", "/invites", Some(token), Some(body)).await;
        assert_eq!(status, StatusCode::OK, "{invite}");
        invite["code"].as_str().unwrap().to_string()
    }
}

fn in_ms(ms: i64) -> i64 {
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap();
    i64::try_from(epoch.as_millis()).unwrap() + ms
}

#[tokio::test]
async fn two_member_creates_return_one_code() {
    let w = world().await;
    let first = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    let second = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    assert_eq!(first, second);

    let (_, listed) = call(&w.router, "GET", "/invites", Some(&w.member), None).await;
    assert_eq!(listed.as_array().unwrap().len(), 1, "only one was minted");
}

#[tokio::test]
async fn without_reuse_every_create_is_a_new_code() {
    let w = world().await;
    let first = w.create(&w.member, json!({"max_uses": 1})).await;
    let second = w.create(&w.member, json!({"max_uses": 1})).await;
    assert_ne!(first, second);
}

#[tokio::test]
async fn each_person_gets_their_own_invite() {
    let w = world().await;
    let mine = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    let theirs = w
        .create(&w.admin, json!({"max_uses": 1, "reuse": true}))
        .await;
    assert_ne!(mine, theirs);
}

#[tokio::test]
async fn a_used_invite_is_replaced() {
    let w = world().await;
    let first = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    let (friend, _) = register(&w.store, "friend").await;
    let (status, _) = call(
        &w.router,
        "POST",
        &format!("/invites/{first}/redeem"),
        Some(&friend),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let second = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    assert_ne!(first, second);
}

#[tokio::test]
async fn a_revoked_invite_is_replaced() {
    let w = world().await;
    let first = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    let (status, _) = call(
        &w.router,
        "DELETE",
        &format!("/invites/{first}"),
        Some(&w.member),
        None,
    )
    .await;
    assert!(status.is_success());
    let second = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    assert_ne!(first, second);
}

#[tokio::test]
async fn an_expired_invite_is_replaced() {
    let w = world().await;
    let body = || json!({"max_uses": 1, "expires_at": in_ms(300), "reuse": true});
    let first = w.create(&w.admin, body()).await;
    assert_eq!(
        first,
        w.create(
            &w.admin,
            json!({"max_uses": 1, "expires_at": in_ms(60_000), "reuse": true})
        )
        .await
    );

    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    let second = w.create(&w.admin, body()).await;
    assert_ne!(first, second);
}

#[tokio::test]
async fn limits_are_part_of_the_kind() {
    let w = world().await;
    let one = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    let three = w
        .create(&w.member, json!({"max_uses": 3, "reuse": true}))
        .await;
    assert_ne!(one, three);
}

#[tokio::test]
async fn a_member_keeps_the_caps_when_reusing() {
    let w = world().await;
    let (status, _) = call(
        &w.router,
        "POST",
        "/invites",
        Some(&w.member),
        Some(json!({"max_uses": 11, "reuse": true})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn turning_the_switch_off_still_revokes_a_reused_invite() {
    let w = world().await;
    let code = w
        .create(&w.member, json!({"max_uses": 1, "reuse": true}))
        .await;
    let (status, _) = call(
        &w.router,
        "PATCH",
        "/space/settings",
        Some(&w.admin),
        Some(json!({"members_can_invite": false})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, check) = call(
        &w.router,
        "GET",
        &format!("/invites/{code}/check"),
        None,
        None,
    )
    .await;
    assert_eq!(check, json!({"usable": false}));
}
