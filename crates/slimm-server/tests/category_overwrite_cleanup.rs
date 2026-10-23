// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A role or account that goes away takes its category overwrites with it, so
//! syncing a channel to its category never copies a dead target back.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelCategoryId, RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

mod support;

use support::app::call_as as call;
use support::overwrite_harness::{app, new_store, register};

struct World {
    app: axum::Router,
    store: Store,
    admin: String,
    category: String,
    channel: String,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let (store, guard) = new_store(prefix).await;
    let app = app(store.clone());
    let (admin, _) = register(&store, "owner").await;
    let (_, category) = call(
        &app,
        "POST",
        "/categories",
        &admin,
        Some(json!({"name": "c"})),
    )
    .await;
    let category = category["id"].as_str().unwrap().to_owned();
    let body = json!({"name": "plans", "category_id": category});
    let (_, channel) = call(&app, "POST", "/channels", &admin, Some(body)).await;
    let channel = channel["id"].as_str().unwrap().to_owned();
    World {
        app,
        store,
        admin,
        category,
        channel,
        _guard: guard,
    }
}

impl World {
    async fn put_category(&self, kind: &str, id: &str) {
        let body = json!({"overwrites": [
            {"kind": kind, "id": id, "allow": Permissions::VIEW_CHANNEL.bits(), "deny": 0}
        ]});
        let uri = format!("/categories/{}/overwrites", self.category);
        let (status, reply) = call(&self.app, "PUT", &uri, &self.admin, Some(body)).await;
        assert_eq!(status, StatusCode::OK, "{reply}");
    }

    async fn category_rows(&self) -> usize {
        let id = ChannelCategoryId(self.category.parse().unwrap());
        self.store.category_overwrites(id).await.unwrap().len()
    }

    async fn sync_channel(&self) -> Value {
        let uri = format!("/channels/{}/overwrites/sync", self.channel);
        let (status, body) = call(&self.app, "POST", &uri, &self.admin, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let uri = format!("/channels/{}/overwrites", self.channel);
        call(&self.app, "GET", &uri, &self.admin, None).await.1["overwrites"].clone()
    }
}

#[tokio::test]
async fn deleting_a_role_removes_its_category_overwrites() {
    let w = world("slimm-catclean-role").await;
    let role = w
        .store
        .create_role("staff", Permissions::NONE, false)
        .await
        .unwrap();
    w.put_category("role", &RoleId(role.0).0.to_string()).await;
    assert_eq!(w.category_rows().await, 1);

    w.store.delete_role(role).await.unwrap();

    assert_eq!(w.category_rows().await, 0);
    let after_sync = w.sync_channel().await;
    assert_eq!(after_sync, json!([]), "the dead role is not copied back");
}

#[tokio::test]
async fn deleting_an_account_removes_the_members_category_overwrites() {
    let w = world("slimm-catclean-member").await;
    let (_, member) = register(&w.store, "leaver").await;
    w.put_category("member", &member).await;
    assert_eq!(w.category_rows().await, 1);

    w.store
        .delete_account(UserId(member.parse().unwrap()))
        .await
        .unwrap();

    assert_eq!(w.category_rows().await, 0);
    assert_eq!(w.sync_channel().await, json!([]));
}
