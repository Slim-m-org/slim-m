// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Category permissions (decision 0064): synced channels carry their
//! category's overwrites, an edit of a channel's own un-syncs it, and a sync
//! adopts the category's again.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, new_store, register, request};

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(method, uri, Some(token), body))
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

struct World {
    app: Router,
    store: Store,
    admin: String,
    member: String,
    staff: String,
    everyone: String,
    staff_role: String,
    category: String,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let (store, guard) = new_store(prefix).await;
    let app = app(store.clone());
    let (admin, _) = register(&store, "owner").await;
    let (member, _) = register(&store, "member").await;
    let (staff, staff_id) = register(&store, "staffer").await;
    let role = store
        .create_role("staff", Permissions::NONE, false)
        .await
        .unwrap();
    store
        .assign_role(UserId(staff_id.parse().unwrap()), role)
        .await
        .unwrap();
    let (_, roles) = call(&app, "GET", "/roles", &admin, None).await;
    let everyone = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["is_everyone"] == json!(true))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let (_, category) = call(
        &app,
        "POST",
        "/categories",
        &admin,
        Some(json!({"name": "staff"})),
    )
    .await;
    World {
        app,
        store,
        admin,
        member,
        staff,
        everyone,
        staff_role: RoleId(role.0).0.to_string(),
        category: category["id"].as_str().unwrap().to_owned(),
        _guard: guard,
    }
}

impl World {
    async fn channel(&self, name: &str, restricted: bool) -> String {
        let body = json!({"name": name, "category_id": self.category, "restricted": restricted});
        let (status, created) = call(&self.app, "POST", "/channels", &self.admin, Some(body)).await;
        assert_eq!(status, StatusCode::OK, "{created}");
        created["id"].as_str().unwrap().to_owned()
    }

    /// The category staff-only: @everyone denied view, the staff role allowed.
    async fn lock_category(&self) -> StatusCode {
        let view = Permissions::VIEW_CHANNEL.bits();
        let body = json!({"overwrites": [
            {"kind": "role", "id": self.everyone, "allow": 0, "deny": view},
            {"kind": "role", "id": self.staff_role, "allow": view, "deny": 0},
        ]});
        let uri = format!("/categories/{}/overwrites", self.category);
        call(&self.app, "PUT", &uri, &self.admin, Some(body))
            .await
            .0
    }

    async fn sees(&self, token: &str, channel: &str) -> bool {
        let (_, list) = call(&self.app, "GET", "/channels", token, None).await;
        list.as_array()
            .unwrap()
            .iter()
            .any(|c| c["id"] == json!(channel))
    }

    async fn synced(&self, channel: &str) -> Value {
        let uri = format!("/channels/{channel}/overwrites");
        call(&self.app, "GET", &uri, &self.admin, None).await.1["synced"].clone()
    }
}

#[tokio::test]
async fn locking_a_category_locks_its_synced_channels() {
    let w = world("slimm-catperm-lock").await;
    let channel = w.channel("plans", false).await;
    assert_eq!(w.synced(&channel).await, json!(true));
    assert!(w.sees(&w.member, &channel).await);

    assert_eq!(w.lock_category().await, StatusCode::OK);
    assert!(
        !w.sees(&w.member, &channel).await,
        "the member lost the channel"
    );
    assert!(w.sees(&w.staff, &channel).await, "staff keep it");

    let later = w.channel("later", false).await;
    assert!(
        !w.sees(&w.member, &later).await,
        "a new channel starts with the category's rules"
    );
    assert!(w.sees(&w.staff, &later).await);
}

#[tokio::test]
async fn editing_a_channel_unsyncs_it_and_sync_brings_it_back() {
    let w = world("slimm-catperm-unsync").await;
    let channel = w.channel("plans", false).await;
    let open = json!({"overwrites": [{"kind": "role", "id": w.everyone, "allow": Permissions::VIEW_CHANNEL.bits(), "deny": 0}]});
    let (status, _) = call(
        &w.app,
        "PUT",
        &format!("/channels/{channel}/overwrites"),
        &w.admin,
        Some(open),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(w.synced(&channel).await, json!(false));

    w.lock_category().await;
    assert!(
        w.sees(&w.member, &channel).await,
        "an unsynced channel keeps its own rules"
    );

    let (status, body) = call(
        &w.app,
        "POST",
        &format!("/channels/{channel}/overwrites/sync"),
        &w.admin,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["synced"], json!(true));
    assert!(
        !w.sees(&w.member, &channel).await,
        "synced again, it follows the category"
    );
}

#[tokio::test]
async fn a_private_channel_and_a_moved_channel_are_not_synced() {
    let w = world("slimm-catperm-private").await;
    let private = w.channel("secret", true).await;
    assert_eq!(w.synced(&private).await, json!(false));

    let channel = w.channel("plans", false).await;
    w.lock_category().await;
    let mut groups: Vec<(Option<String>, Vec<String>)> = vec![(None, Vec::new())];
    for category in w.store.list_categories().await.unwrap() {
        groups.push((Some(category.id.to_string()), Vec::new()));
    }
    for c in w.store.list_channels().await.unwrap() {
        let key = if c.id.to_string() == channel {
            None
        } else {
            c.category_id.map(|id| id.to_string())
        };
        groups
            .iter_mut()
            .find(|(k, _)| *k == key)
            .unwrap()
            .1
            .push(c.id.to_string());
    }
    let categories: Vec<Value> = groups
        .into_iter()
        .map(|(id, ids)| json!({"category_id": id, "channel_ids": ids}))
        .collect();
    let body = json!({"categories": categories});
    let (status, moved) = call(&w.app, "PUT", "/channels/order", &w.admin, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{moved}");
    assert_eq!(
        w.synced(&channel).await,
        json!(false),
        "a move stops following"
    );
    assert!(
        !w.sees(&w.member, &channel).await,
        "but keeps the rules it had"
    );

    let (status, _) = call(
        &w.app,
        "POST",
        &format!("/channels/{channel}/overwrites/sync"),
        &w.admin,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "no category to follow");
}

#[tokio::test]
async fn only_a_role_manager_changes_category_permissions() {
    let w = world("slimm-catperm-gate").await;
    let uri = format!("/categories/{}/overwrites", w.category);
    assert_eq!(
        call(&w.app, "GET", &uri, &w.member, None).await.0,
        StatusCode::FORBIDDEN
    );
    let body = json!({"overwrites": [{"kind": "role", "id": w.everyone, "allow": 0, "deny": 2}]});
    assert_eq!(
        call(&w.app, "PUT", &uri, &w.member, Some(body)).await.0,
        StatusCode::FORBIDDEN
    );
    let missing = format!("/categories/{}/overwrites", uuid::Uuid::now_v7());
    assert_eq!(
        call(&w.app, "GET", &missing, &w.admin, None).await.0,
        StatusCode::NOT_FOUND
    );
}
