// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel manager listed a private category only as the heading over a sub-category they can
//! view may not rename, delete or move it: each answers as for a category that does not exist,
//! and a reorder keeps it where it is. The sub-category itself stays theirs to manage.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::TestApp;

const VIEW: i64 = Permissions::VIEW_CHANNEL.bits();

struct World {
    app: TestApp,
    /// Private to everyone; listed to the manager only as `cs`'s heading.
    gamers: String,
    /// Under `gamers`, private but for the manager.
    cs: String,
    open: String,
}

impl World {
    async fn start(prefix: &str) -> Self {
        let app = TestApp::start(prefix).await;
        let role = app
            .create_role("builders", Permissions::MANAGE_CHANNELS.bits())
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
            .clone();
        let gamers = create(&app, json!({"name": "Gamers"})).await;
        let open = create(&app, json!({"name": "Open"})).await;
        let cs = create(&app, json!({"name": "CS", "parent_id": gamers})).await;
        let shut = json!({"kind": "role", "id": everyone, "deny": VIEW});
        let me = json!({"kind": "member", "id": app.member.id.to_string(), "allow": VIEW});
        for (category, rows) in [(&gamers, json!([shut])), (&cs, json!([shut, me]))] {
            let uri = format!("/categories/{category}/overwrites");
            let body = json!({"overwrites": rows});
            let (status, answer) = app.call("PUT", &uri, admin, Some(body)).await;
            assert_eq!(status, StatusCode::OK, "{answer}");
        }
        Self {
            app,
            gamers,
            cs,
            open,
        }
    }

    async fn categories(&self, token: &str) -> Vec<Value> {
        let (status, body) = self.app.call("GET", "/categories", token, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body.as_array().unwrap().clone()
    }

    async fn admin_sees(&self, id: &str) -> Value {
        let all = self.categories(&self.app.admin.token).await;
        all.into_iter()
            .find(|c| c["id"] == id)
            .unwrap_or(Value::Null)
    }

    /// The manager's answer for `uri` naming `gamers`, and naming a fresh id in its place.
    async fn ask_twice(&self, method: &str, uri: &str, body: Value) -> [(StatusCode, String); 2] {
        let nowhere = uuid::Uuid::now_v7().to_string();
        let manager = &self.app.member.token;
        let named = self
            .app
            .call(method, uri, manager, Some(body.clone()))
            .await;
        let elsewhere = uri.replace(&self.gamers, &nowhere);
        let unknown = self.app.call(method, &elsewhere, manager, Some(body)).await;
        [
            (named.0, named.1.to_string().replace(&self.gamers, "ID")),
            (unknown.0, unknown.1.to_string().replace(&nowhere, "ID")),
        ]
    }
}

async fn create(app: &TestApp, body: Value) -> String {
    let (status, created) = app
        .call("POST", "/categories", &app.admin.token, Some(body))
        .await;
    assert_eq!(status, StatusCode::OK, "{created}");
    created["id"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn a_heading_is_listed_as_one_the_manager_may_not_manage() {
    let world = World::start("slimm-category-heading-list").await;
    let listed = world.categories(&world.app.member.token).await;
    let flag = |id: &str| {
        listed
            .iter()
            .find(|c| c["id"] == id)
            .map(|c| c["manageable"].clone())
    };
    assert_eq!(flag(&world.gamers), Some(json!(false)));
    assert_eq!(flag(&world.cs), Some(json!(true)));
    assert_eq!(flag(&world.open), Some(json!(true)));
    let all = world.categories(&world.app.admin.token).await;
    assert!(all.iter().all(|c| c["manageable"] == true), "{all:?}");
}

#[tokio::test]
async fn a_heading_cannot_be_renamed_moved_or_deleted_by_the_manager() {
    let world = World::start("slimm-category-heading-write").await;
    let uri = format!("/categories/{}", world.gamers);
    for patch in [json!({"name": "mine"}), json!({"parent_id": world.open})] {
        let [named, unknown] = world.ask_twice("PATCH", &uri, patch).await;
        assert_eq!(named.0, StatusCode::NOT_FOUND, "{}", named.1);
        assert_eq!(named, unknown, "a heading answers like no category");
    }
    let [named, unknown] = world.ask_twice("DELETE", &uri, json!({})).await;
    assert_eq!(named.0, StatusCode::NO_CONTENT);
    assert_eq!(named, unknown);

    let kept = world.admin_sees(&world.gamers).await;
    assert_eq!(
        (kept["name"].as_str(), kept["parent_id"].as_str()),
        (Some("Gamers"), None)
    );
    assert_eq!(
        world.admin_sees(&world.cs).await["parent_id"],
        world.gamers.as_str()
    );

    let rename = json!({"name": "Counter-Strike"});
    let mine = format!("/categories/{}", world.cs);
    let (status, body) = world
        .app
        .call("PATCH", &mine, &world.app.member.token, Some(rename))
        .await;
    assert_eq!(status, StatusCode::OK, "the sub-category is theirs: {body}");
}

#[tokio::test]
async fn a_reorder_keeps_a_heading_where_it_is() {
    let world = World::start("slimm-category-heading-order").await;
    let listed = world.categories(&world.app.member.token).await;
    let top: Vec<&Value> = listed
        .iter()
        .filter(|c| c["parent_id"].is_null())
        .map(|c| &c["id"])
        .rev()
        .collect();
    let before: Vec<String> = top_names(&world.categories(&world.app.admin.token).await);
    let gamers_at = before.iter().position(|n| n == "Gamers").unwrap();
    let order = json!({"groups": [
        {"parent_id": null, "category_ids": top},
        {"parent_id": world.gamers, "category_ids": [world.cs]},
    ]});
    let (status, body) = world
        .app
        .call(
            "PUT",
            "/categories/order",
            &world.app.member.token,
            Some(order),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let after = top_names(&world.categories(&world.app.admin.token).await);
    assert_eq!(after.iter().position(|n| n == "Gamers"), Some(gamers_at));
    let mut others: Vec<&String> = before.iter().filter(|n| *n != "Gamers").collect();
    others.reverse();
    let moved: Vec<&String> = after.iter().filter(|n| *n != "Gamers").collect();
    assert_eq!(moved, others, "the rest took the order asked for");
}

fn top_names(categories: &[Value]) -> Vec<String> {
    categories
        .iter()
        .filter(|c| c["parent_id"].is_null())
        .map(|c| c["name"].as_str().unwrap().to_owned())
        .collect()
}
