// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The role ladder on moderation: time out, rename, remove, delete an account and their bulk
//! forms reach only members whose highest role sits strictly below the caller's own; the Space
//! owner reaches everyone and nobody reaches the owner.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

use crate::support;
use support::app::{app, call_as, register_token_id as register};

const LADDER: &str = "role_hierarchy";

/// alice owns the Space. erin holds `admin` too; bob and dave hold `mod`, carol `helper`, and
/// frank nothing, ordered admin > mod > helper.
struct World {
    app: Router,
    store: Store,
    pool: sqlx::SqlitePool,
    alice: (String, String),
    bob: (String, String),
    carol: (String, String),
    dave: (String, String),
    erin: (String, String),
    frank: (String, String),
    _guard: support::TestDbGuard,
}

async fn ok(app: &Router, token: &str, method: &str, uri: &str, body: Option<Value>) -> Value {
    let (status, body) = call_as(app, method, uri, token, body).await;
    assert!(status.is_success(), "{method} {uri}: {status} {body}");
    body
}

async fn role(app: &Router, token: &str, name: &str, permissions: Permissions) -> String {
    let body = json!({ "name": name, "permissions": permissions.bits() });
    ok(app, token, "POST", "/roles", Some(body)).await["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn world() -> World {
    let (store, pool, guard) = support::new_store_with_pool("slimm-member-ladder").await;
    let app = app(store.clone());
    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let carol = register(&store, "carol").await;
    let dave = register(&store, "dave").await;
    let erin = register(&store, "erin").await;
    let frank = register(&store, "frank").await;
    let moderating = Permissions::KICK_MEMBERS.union(Permissions::BAN_MEMBERS);
    let mods = role(&app, &alice.0, "mod", moderating).await;
    let helpers = role(&app, &alice.0, "helper", moderating).await;
    let admin = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id
        .to_string();
    let order = json!({ "role_ids": [&admin, &mods, &helpers] });
    ok(&app, &alice.0, "PATCH", "/roles/reorder", Some(order)).await;
    for (user, held) in [
        (&bob, &mods),
        (&dave, &mods),
        (&carol, &helpers),
        (&erin, &admin),
    ] {
        let uri = format!("/members/{}/roles/{held}", user.1);
        ok(&app, &alice.0, "PUT", &uri, None).await;
    }
    World {
        app,
        store,
        pool,
        alice,
        bob,
        carol,
        dave,
        erin,
        frank,
        _guard: guard,
    }
}

impl World {
    async fn time_out(&self, actor: &(String, String), target: &str) -> (StatusCode, Value) {
        let uri = format!("/members/{target}/timeout");
        let body = json!({ "duration_seconds": 60 });
        call_as(&self.app, "PUT", &uri, &actor.0, Some(body)).await
    }

    async fn timed_out(&self, user: &str) -> bool {
        let profile = ok(
            &self.app,
            &self.alice.0,
            "GET",
            &format!("/users/{user}"),
            None,
        )
        .await;
        !profile["timed_out_until"].is_null()
    }
}

fn refused(result: (StatusCode, Value)) -> Value {
    assert_eq!(result.0, StatusCode::FORBIDDEN, "{}", result.1);
    assert_eq!(result.1["code"], LADDER, "{}", result.1);
    result.1
}

#[tokio::test]
async fn a_moderator_acts_on_members_below_and_on_members_with_no_role() {
    let w = world().await;
    assert_eq!(w.time_out(&w.bob, &w.carol.1).await.0, StatusCode::OK);
    assert_eq!(w.time_out(&w.carol, &w.frank.1).await.0, StatusCode::OK);
    let uri = format!("/members/{}/nickname", w.carol.1);
    let (status, _) = call_as(
        &w.app,
        "PUT",
        &uri,
        &w.bob.0,
        Some(json!({ "nickname": "c" })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_peer_is_refused_as_equal_rank_and_a_senior_as_out_of_reach() {
    let w = world().await;
    let body = refused(w.time_out(&w.bob, &w.dave.1).await);
    assert_eq!(body["error"], "you cannot act on someone of equal rank");
    refused(w.time_out(&w.carol, &w.bob.1).await);
    let uri = format!("/members/{}/removal", w.bob.1);
    refused(call_as(&w.app, "PUT", &uri, &w.carol.0, Some(json!({}))).await);
    let uri = format!("/members/{}/nickname", w.bob.1);
    refused(
        call_as(
            &w.app,
            "PUT",
            &uri,
            &w.carol.0,
            Some(json!({ "nickname": "b" })),
        )
        .await,
    );
    assert!(!w.timed_out(&w.dave.1).await && !w.timed_out(&w.bob.1).await);
}

#[tokio::test]
async fn nobody_acts_on_the_owner_not_even_an_administrator() {
    let w = world().await;
    let owner = &w.alice.1;
    refused(w.time_out(&w.erin, owner).await);
    let removal = format!("/members/{owner}/removal");
    refused(call_as(&w.app, "PUT", &removal, &w.erin.0, Some(json!({}))).await);
    let nickname = format!("/members/{owner}/nickname");
    refused(
        call_as(
            &w.app,
            "PUT",
            &nickname,
            &w.erin.0,
            Some(json!({ "nickname": "a" })),
        )
        .await,
    );
    let account = format!("/members/{owner}/account");
    refused(call_as(&w.app, "DELETE", &account, &w.erin.0, None).await);
    assert!(!w.timed_out(owner).await);
}

/// erin holds the same top role as the owner, which only the owner may pass.
#[tokio::test]
async fn the_owner_reaches_a_fellow_administrator_who_reaches_everyone_below() {
    let w = world().await;
    assert_eq!(w.time_out(&w.alice, &w.erin.1).await.0, StatusCode::OK);
    let (status, _) = w.time_out(&w.erin, &w.bob.1).await;
    assert_eq!(status, StatusCode::OK);
    let account = format!("/members/{}/account", w.frank.1);
    let (status, body) = call_as(&w.app, "DELETE", &account, &w.erin.0, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
}

#[tokio::test]
async fn a_bulk_act_follows_the_ladder_for_every_target_before_writing_any() {
    let w = world().await;
    let timeout = |ids: Vec<&String>| json!({ "user_ids": ids, "duration_seconds": 60 });
    let (status, body) = call_as(
        &w.app,
        "POST",
        "/members/bulk-timeout",
        &w.bob.0,
        Some(timeout(vec![&w.carol.1, &w.dave.1])),
    )
    .await;
    refused((status, body));
    assert!(!w.timed_out(&w.carol.1).await);

    let (status, _) = call_as(
        &w.app,
        "POST",
        "/members/bulk-timeout",
        &w.bob.0,
        Some(timeout(vec![&w.carol.1, &w.frank.1])),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(w.timed_out(&w.carol.1).await && w.timed_out(&w.frank.1).await);

    let removal = json!({ "user_ids": [&w.alice.1] });
    let result = call_as(
        &w.app,
        "POST",
        "/members/bulk-removal",
        &w.erin.0,
        Some(removal),
    )
    .await;
    refused(result);
    let removal = json!({ "user_ids": [&w.frank.1] });
    let (status, _) = call_as(
        &w.app,
        "POST",
        "/members/bulk-removal",
        &w.bob.0,
        Some(removal),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

/// Deleting the owner hands the Space to the earliest-joined administrator, here erin, who
/// joined after bob, carol and dave.
#[tokio::test]
async fn ownership_passes_to_the_earliest_administrator_then_the_earliest_member() {
    let w = world().await;
    let me = |token: String| {
        let app = w.app.clone();
        async move { ok(&app, &token, "GET", "/me", None).await["is_owner"].clone() }
    };
    assert_eq!(me(w.alice.0.clone()).await, true);
    let alice = slimm_server::ids::UserId(w.alice.1.parse().unwrap());
    w.store.delete_account(alice).await.unwrap();
    assert_eq!(me(w.erin.0.clone()).await, true);
    assert_eq!(me(w.bob.0.clone()).await, false);
    assert_eq!(w.time_out(&w.erin, &w.bob.1).await.0, StatusCode::OK);

    let erin = slimm_server::ids::UserId(w.erin.1.parse().unwrap());
    let bob = slimm_server::ids::UserId(w.bob.1.parse().unwrap());
    // Leaves no administrator at all, which no route allows, to reach the last fallback.
    for sql in [
        "DELETE FROM member_roles WHERE user_id = ?",
        "UPDATE users SET deleted_at = 1 WHERE id = ?",
    ] {
        sqlx::query(sql).bind(erin).execute(&w.pool).await.unwrap();
    }
    let settled = w.store.settle_space_owner().await.unwrap();
    assert_eq!(settled.owner, Some(bob));
}
