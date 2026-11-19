// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A private category keeps a role manager out the way a private channel does:
//! MANAGE_ROLES edits a category only as far as its holder's own permissions
//! under that category's rows reach, so nobody adds themselves to one they
//! cannot see, and whoever makes a category private stays in it (decision 0125).

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::TestApp;

const VIEW: i64 = Permissions::VIEW_CHANNEL.bits();

struct World {
    app: TestApp,
    everyone: String,
    category: String,
    /// A channel synced with `category`.
    channel: String,
}

impl World {
    /// `member` holds MANAGE_ROLES and nothing else beyond `@everyone`.
    async fn start(prefix: &str) -> Self {
        let app = TestApp::start(prefix).await;
        let role = app
            .create_role("managers", Permissions::MANAGE_ROLES.bits())
            .await;
        let grant = format!("/members/{}/roles/{role}", app.member.id);
        let (status, body) = app.call("PUT", &grant, &app.admin.token, None).await;
        assert!(status.is_success(), "grant: {status} {body}");

        let admin = &app.admin.token;
        let (_, roles) = app.call("GET", "/roles", admin, None).await;
        let everyone = roles
            .as_array()
            .unwrap()
            .iter()
            .find(|role| role["is_everyone"] == true)
            .expect("@everyone")["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let named = json!({"name": "Staff"});
        let (_, category) = app.call("POST", "/categories", admin, Some(named)).await;
        let category = category["id"].as_str().expect("a category").to_owned();
        let inside = json!({"name": "staff-room", "category_id": category});
        let (_, channel) = app.call("POST", "/channels", admin, Some(inside)).await;
        let channel = channel["id"].as_str().expect("a channel").to_owned();
        Self {
            app,
            everyone,
            category,
            channel,
        }
    }

    fn rows(&self, extra: &[Value]) -> Value {
        let mut rows = vec![json!({"kind": "role", "id": self.everyone, "deny": VIEW})];
        rows.extend_from_slice(extra);
        json!({"overwrites": rows})
    }

    async fn write(&self, token: &str, category: &str, rows: Value) -> (StatusCode, Value) {
        let uri = format!("/categories/{category}/overwrites");
        self.app.call("PUT", &uri, token, Some(rows)).await
    }

    async fn reads_the_channel(&self, token: &str) -> StatusCode {
        let uri = format!("/channels/{}/messages", self.channel);
        self.app.call("GET", &uri, token, None).await.0
    }
}

#[tokio::test]
async fn a_role_manager_cannot_let_themselves_into_a_private_category() {
    let world = World::start("slimm-category-hidden-break-in").await;
    let (admin, manager) = (&world.app.admin.token, &world.app.member.token);
    let (status, body) = world.write(admin, &world.category, world.rows(&[])).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        world.reads_the_channel(manager).await,
        StatusCode::FORBIDDEN
    );

    let me = json!({"kind": "member", "id": world.app.member.id.to_string(), "allow": VIEW});
    let nowhere = uuid::Uuid::now_v7().to_string();
    let refused = world
        .write(
            manager,
            &world.category,
            world.rows(std::slice::from_ref(&me)),
        )
        .await;
    let unknown = world.write(manager, &nowhere, world.rows(&[me])).await;
    assert_eq!(refused.0, StatusCode::NOT_FOUND, "{}", refused.1);
    assert_eq!(
        refused, unknown,
        "a hidden category answers like no category"
    );
    assert_eq!(
        world.reads_the_channel(manager).await,
        StatusCode::FORBIDDEN
    );

    let uri = format!("/categories/{}/overwrites", world.category);
    let (status, body) = world.app.call("GET", &uri, manager, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "who is in it: {body}");
}

#[tokio::test]
async fn whoever_makes_a_category_private_stays_in_and_can_open_it_again() {
    let world = World::start("slimm-category-hidden-own").await;
    let manager = &world.app.member.token;
    let me = json!({"kind": "member", "id": world.app.member.id.to_string(), "allow": VIEW});

    let (status, body) = world
        .write(manager, &world.category, world.rows(&[me]))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(world.reads_the_channel(manager).await, StatusCode::OK);

    let open = json!({"overwrites": [{"kind": "role", "id": world.everyone}]});
    let (status, body) = world.write(manager, &world.category, open).await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn a_role_manager_cannot_sync_a_sub_category_they_cannot_see() {
    let world = World::start("slimm-category-hidden-sync").await;
    let (admin, manager) = (&world.app.admin.token, &world.app.member.token);
    let nested = json!({"name": "Leads", "parent_id": world.category});
    let (_, sub) = world
        .app
        .call("POST", "/categories", admin, Some(nested))
        .await;
    let sub = sub["id"].as_str().expect("a sub-category").to_owned();
    let (status, body) = world.write(admin, &sub, world.rows(&[])).await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let uri = format!("/categories/{sub}/overwrites/sync");
    let (status, body) = world.app.call("POST", &uri, manager, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    let (_, kept) = world
        .app
        .call("GET", &format!("/categories/{sub}/overwrites"), admin, None)
        .await;
    assert_eq!(
        kept["overwrites"].as_array().map(Vec::len),
        Some(1),
        "{kept}"
    );
}
