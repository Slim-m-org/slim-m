// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The role ladder on permission overwrites: one on a role edits that role in one place, and one
//! on a member acts on them, so a manager reaches only roles and members below their highest role.
//! Nobody but the owner gives the owner a role either, since a role can carry denials.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::RoleId;
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::{app, call_as, general_channel_id, register_token_id as register};

/// alice owns the Space; mo holds `mod` (MANAGE_ROLES), sam `senior` above it, jay `junior` below.
struct World {
    app: Router,
    alice: (String, String),
    mo: String,
    sam: String,
    jay: String,
    senior: RoleId,
    junior: RoleId,
    everyone: RoleId,
    channel: String,
    category: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-overwrite-ladder").await;
    let app = app(store.clone());
    let alice = register(&store, "alice").await;
    let (mo, mo_id) = register(&store, "mo").await;
    let (_, sam) = register(&store, "sam").await;
    let (_, jay) = register(&store, "jay").await;
    let none = Permissions::NONE;
    let senior = store.create_role("senior", none, false).await.unwrap();
    let managing = Permissions::MANAGE_ROLES;
    let mods = store.create_role("mod", managing, false).await.unwrap();
    let junior = store.create_role("junior", none, false).await.unwrap();
    let roles = store.list_roles().await.unwrap();
    let admin = roles.iter().find(|r| r.name == "admin").unwrap().id;
    let everyone = roles.iter().find(|r| r.is_everyone).unwrap().id;
    store
        .reorder_roles(&[admin, senior, mods, junior])
        .await
        .unwrap();
    for (user, role) in [(&mo_id, mods), (&sam, senior), (&jay, junior)] {
        let user = slimm_server::ids::UserId(user.parse().unwrap());
        store.assign_role(user, role).await.unwrap();
    }
    let category = store.create_category("Rooms").await.unwrap().id.to_string();
    World {
        channel: general_channel_id(&store).await,
        app,
        alice,
        mo,
        sam,
        jay,
        senior,
        junior,
        everyone,
        category,
        _guard: guard,
    }
}

fn deny() -> Value {
    json!({ "allow": 0, "deny": Permissions::SEND_MESSAGES.bits() })
}

fn refused(result: (StatusCode, Value)) {
    assert_eq!(result.0, StatusCode::FORBIDDEN, "{}", result.1);
    assert_eq!(result.1["code"], "role_hierarchy", "{}", result.1);
}

fn entry(kind: &str, id: &str) -> Value {
    json!({ "kind": kind, "id": id, "allow": 0, "deny": Permissions::SEND_MESSAGES.bits() })
}

impl World {
    async fn put(&self, kind: &str, id: &str) -> (StatusCode, Value) {
        let uri = format!("/channels/{}/overwrites/{kind}/{id}", self.channel);
        call_as(&self.app, "PUT", &uri, &self.mo, Some(deny())).await
    }

    async fn batch(&self, uri: &str, entries: Vec<Value>) -> (StatusCode, Value) {
        let body = json!({ "overwrites": entries });
        call_as(&self.app, "PUT", uri, &self.mo, Some(body)).await
    }
}

#[tokio::test]
async fn a_manager_overrides_only_roles_and_members_below_them() {
    let w = world().await;
    refused(w.put("member", &w.alice.1).await);
    refused(w.put("member", &w.sam).await);
    refused(w.put("role", &w.senior.to_string()).await);
    let clear = format!("/channels/{}/overwrites/member/{}", w.channel, w.alice.1);
    refused(call_as(&w.app, "DELETE", &clear, &w.mo, None).await);

    for (kind, id) in [
        ("member", w.jay.clone()),
        ("role", w.junior.to_string()),
        ("role", w.everyone.to_string()),
    ] {
        let (status, body) = w.put(kind, &id).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{kind} {id}: {body}");
    }
}

#[tokio::test]
async fn a_batch_is_refused_whole_for_one_target_out_of_reach() {
    let w = world().await;
    let channel = format!("/channels/{}/overwrites", w.channel);
    let category = format!("/categories/{}/overwrites", w.category);
    for uri in [&channel, &category] {
        let entries = vec![entry("member", &w.jay), entry("member", &w.alice.1)];
        refused(w.batch(uri, entries).await);
        let entries = vec![entry("role", &w.senior.to_string())];
        refused(w.batch(uri, entries).await);
        let (status, body) = w.batch(uri, vec![entry("member", &w.jay)]).await;
        assert!(status.is_success(), "{uri}: {status} {body}");
    }
}

/// A role carrying denials would otherwise be a way to lock the owner out that only they could undo.
#[tokio::test]
async fn only_the_owner_gives_the_owner_a_role() {
    let w = world().await;
    let uri = format!("/members/{}/roles/{}", w.alice.1, w.junior);
    refused(call_as(&w.app, "PUT", &uri, &w.mo, None).await);
    let (status, body) = call_as(&w.app, "PUT", &uri, &w.alice.0, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
}
