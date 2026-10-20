// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Members inviting a friend: the owner switch, the safe defaults and caps a
//! member-made invite gets, and the owner seeing and revoking them.

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
    let (store, guard) = new_store("slimm-member-invites").await;
    let (admin, _) = register(&store, "root").await;
    let (member, _) = register(&store, "nia").await;
    World {
        router: builder(store.clone()).router(),
        store,
        admin,
        member,
        _guard: guard,
    }
}

impl World {
    async fn set_switch(&self, enabled: bool) {
        let (status, body) = call(
            &self.router,
            "PATCH",
            "/space/settings",
            Some(&self.admin),
            Some(json!({"members_can_invite": enabled})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["members_can_invite"], enabled);
    }

    async fn invite(&self, token: &str, body: Value) -> (StatusCode, Value) {
        call(&self.router, "POST", "/invites", Some(token), Some(body)).await
    }
}

#[tokio::test]
async fn a_member_is_refused_while_the_switch_is_off() {
    let w = world().await;
    let (_, version) = call(&w.router, "GET", "/version", None, None).await;
    assert_eq!(version["members_can_invite"], false);

    let (status, _) = w.invite(&w.member, json!({})).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn only_a_manager_can_flip_the_switch() {
    let w = world().await;
    let (status, _) = call(
        &w.router,
        "PATCH",
        "/space/settings",
        Some(&w.member),
        Some(json!({"members_can_invite": true})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_member_invite_defaults_to_one_use_and_a_day() {
    let w = world().await;
    w.set_switch(true).await;
    let (_, version) = call(&w.router, "GET", "/version", None, None).await;
    assert_eq!(version["members_can_invite"], true);

    let (status, invite) = w.invite(&w.member, json!({})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(invite["max_uses"], 1);
    let expires = invite["expires_at"].as_i64().unwrap();
    let day = 24 * 60 * 60 * 1000;
    let created = invite["created_at"].as_i64().unwrap();
    assert!((expires - created - day).abs() < 60_000);
}

#[tokio::test]
async fn a_member_cannot_ask_past_the_caps_or_grant_a_role() {
    let w = world().await;
    w.set_switch(true).await;

    let (status, _) = w.invite(&w.member, json!({"max_uses": 11})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let far = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        + 8 * 24 * 60 * 60 * 1000;
    let (status, _) = w.invite(&w.member, json!({"expires_at": far})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = w
        .invite(
            &w.member,
            json!({"role_grant": uuid::Uuid::now_v7().to_string()}),
        )
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, invite) = w.invite(&w.member, json!({"max_uses": 10})).await;
    assert_eq!((status, &invite["max_uses"]), (StatusCode::OK, &json!(10)));
}

#[tokio::test]
async fn a_member_invite_stops_working_after_its_single_use() {
    let w = world().await;
    w.set_switch(true).await;
    let (_, invite) = w.invite(&w.member, json!({})).await;
    let code = invite["code"].as_str().unwrap();
    let (friend, _) = register(&w.store, "friend").await;

    let (status, _) = call(
        &w.router,
        "POST",
        &format!("/invites/{code}/redeem"),
        Some(&friend),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

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

#[tokio::test]
async fn the_owner_sees_who_made_each_invite_and_revokes_it() {
    let w = world().await;
    w.set_switch(true).await;
    let (_, invite) = w.invite(&w.member, json!({})).await;
    let code = invite["code"].as_str().unwrap();

    let (_, theirs) = call(&w.router, "GET", "/invites", Some(&w.member), None).await;
    assert_eq!(theirs.as_array().unwrap().len(), 1);

    let (_, all) = call(&w.router, "GET", "/invites", Some(&w.admin), None).await;
    let row = &all.as_array().unwrap()[0];
    assert_eq!(row["code"], code);
    assert_eq!(row["created_by_name"], "nia");

    let (status, _) = call(
        &w.router,
        "DELETE",
        &format!("/invites/{code}"),
        Some(&w.admin),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, check) = call(
        &w.router,
        "GET",
        &format!("/invites/{code}/check"),
        None,
        None,
    )
    .await;
    assert_eq!(check, json!({"usable": false}));

    let (_, log) = call(&w.router, "GET", "/space/audit-log", Some(&w.admin), None).await;
    let actions: Vec<&str> = log
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|entry| entry["action"].as_str())
        .collect();
    assert!(actions.contains(&"invite.create"), "{actions:?}");
    assert!(actions.contains(&"invite.revoke"), "{actions:?}");
}

#[tokio::test]
async fn turning_the_switch_off_closes_creation_again() {
    let w = world().await;
    w.set_switch(true).await;
    w.set_switch(false).await;
    let (status, _) = w.invite(&w.member, json!({})).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}
