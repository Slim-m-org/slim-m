// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! MANAGE_CHANNELS reaches only the categories its holder is listed: a private
//! one is not listed to them, and renaming, deleting, filing anything under or
//! naming it in an order answers exactly like a category that does not exist.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::TestApp;

const VIEW: i64 = Permissions::VIEW_CHANNEL.bits();

struct World {
    app: TestApp,
    /// Private to everyone but the admin, with a channel synced to it.
    staff: String,
    open: String,
    /// A private sub-category of `open`.
    secret_sub: String,
}

impl World {
    /// `member` holds MANAGE_CHANNELS; the top level is the default Text and Voice, then staff, open, other.
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
        let private = json!({"overwrites": [{"kind": "role", "id": everyone, "deny": VIEW}]});
        let staff = create(&app, json!({"name": "Staff"})).await;
        let open = create(&app, json!({"name": "Open"})).await;
        create(&app, json!({"name": "Other"})).await;
        let secret_sub = create(&app, json!({"name": "Secret", "parent_id": open})).await;
        for category in [&staff, &secret_sub] {
            let uri = format!("/categories/{category}/overwrites");
            let (status, body) = app.call("PUT", &uri, admin, Some(private.clone())).await;
            assert_eq!(status, StatusCode::OK, "{body}");
        }
        let inside = json!({"name": "staff-room", "category_id": staff});
        let (status, body) = app.call("POST", "/channels", admin, Some(inside)).await;
        assert!(status.is_success(), "{status} {body}");
        Self {
            app,
            staff,
            open,
            secret_sub,
        }
    }

    async fn categories(&self, token: &str) -> Vec<Value> {
        let (status, body) = self.app.call("GET", "/categories", token, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body.as_array().unwrap().clone()
    }

    async fn admin_sees(&self, id: &str) -> Value {
        let all = self.categories(&self.app.admin.token).await;
        let found = all.into_iter().find(|c| c["id"] == id);
        found.unwrap_or(Value::Null)
    }

    /// Asks `uri` as the manager naming `hidden`, then naming a fresh id in its place.
    async fn ask_twice(&self, method: &str, uri: &str, body: Value, hidden: &str) -> [Answer; 2] {
        let nowhere = uuid::Uuid::now_v7().to_string();
        let manager = &self.app.member.token;
        let named = self
            .app
            .call(method, uri, manager, Some(body.clone()))
            .await;
        let stranger = |text: &str| text.replace(hidden, &nowhere);
        let unknown_body = serde_json::from_str(&stranger(&body.to_string())).unwrap();
        let unknown = self
            .app
            .call(method, &stranger(uri), manager, Some(unknown_body))
            .await;
        let named_text = named.1.to_string().replace(hidden, "ID");
        let unknown_text = unknown.1.to_string().replace(&nowhere, "ID");
        [(named.0, named_text), (unknown.0, unknown_text)]
    }
}

type Answer = (StatusCode, String);

async fn create(app: &TestApp, body: Value) -> String {
    let (status, created) = app
        .call("POST", "/categories", &app.admin.token, Some(body))
        .await;
    assert_eq!(status, StatusCode::OK, "{created}");
    created["id"].as_str().unwrap().to_owned()
}

fn names(listed: &[Value]) -> Vec<&str> {
    listed.iter().map(|c| c["name"].as_str().unwrap()).collect()
}

#[tokio::test]
async fn a_manager_is_not_listed_a_category_they_cannot_view() {
    let world = World::start("slimm-category-manage-hidden-list").await;
    let listed = world.categories(&world.app.member.token).await;
    assert_eq!(names(&listed), ["Text", "Voice", "Open", "Other"]);
    let raw = Value::Array(listed).to_string();
    for hidden in [&world.staff, &world.secret_sub] {
        assert!(!raw.contains(hidden.as_str()), "{hidden} leaked: {raw}");
    }
    let all = world.categories(&world.app.admin.token).await;
    assert_eq!(
        names(&all),
        ["Text", "Voice", "Staff", "Open", "Secret", "Other"]
    );
}

#[tokio::test]
async fn a_manager_cannot_rename_or_delete_a_category_they_cannot_view() {
    let world = World::start("slimm-category-manage-hidden-write").await;
    for hidden in [&world.staff, &world.secret_sub] {
        let uri = format!("/categories/{hidden}");
        let rename = json!({"name": "mine"});
        let [named, unknown] = world.ask_twice("PATCH", &uri, rename, hidden).await;
        assert_eq!(named.0, StatusCode::NOT_FOUND, "{}", named.1);
        assert_eq!(named, unknown, "a hidden category answers like none");
        let [named, unknown] = world.ask_twice("DELETE", &uri, json!({}), hidden).await;
        assert_eq!(named, unknown, "a hidden category answers like none");
        assert!(!world.admin_sees(hidden).await.is_null(), "it was deleted");
    }
    assert_eq!(world.admin_sees(&world.staff).await["name"], "Staff");
    assert_eq!(world.admin_sees(&world.secret_sub).await["name"], "Secret");
}

#[tokio::test]
async fn a_manager_cannot_file_anything_under_a_category_they_cannot_view() {
    let world = World::start("slimm-category-manage-hidden-file").await;
    let staff = world.staff.as_str();
    world.app.create_channel("lounge").await;
    let (_, seen) = world
        .app
        .call("GET", "/channels", &world.app.member.token, None)
        .await;
    let seen: Vec<&Value> = seen.as_array().unwrap().iter().map(|c| &c["id"]).collect();
    let asks = [
        (
            "POST",
            "/channels".to_owned(),
            json!({"name": "mine", "category_id": staff}),
        ),
        (
            "POST",
            "/categories".to_owned(),
            json!({"name": "mine", "parent_id": staff}),
        ),
        (
            "PATCH",
            format!("/categories/{}", world.open),
            json!({"parent_id": staff}),
        ),
        (
            "PUT",
            "/channels/order".to_owned(),
            json!({"categories": [{"category_id": staff, "channel_ids": seen}]}),
        ),
    ];
    for (method, uri, body) in asks {
        let [named, unknown] = world.ask_twice(method, &uri, body, staff).await;
        assert!(named.0.is_client_error(), "{method} {uri}: {named:?}");
        assert_eq!(named, unknown, "{method} {uri}");
    }
    let (_, channels) = world
        .app
        .call("GET", "/channels", &world.app.admin.token, None)
        .await;
    let filed = channels
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["category_id"] == staff);
    assert_eq!(filed.count(), 1, "only staff-room is in Staff");
    assert!(world.admin_sees(&world.open).await["parent_id"].is_null());
}

#[tokio::test]
async fn a_manager_reorders_what_they_see_around_the_categories_they_cannot() {
    let world = World::start("slimm-category-manage-hidden-order").await;
    let listed = world.categories(&world.app.member.token).await;
    let ids: Vec<&Value> = listed.iter().map(|c| &c["id"]).rev().collect();
    let order = json!({"groups": [{"parent_id": null, "category_ids": ids}]});
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
    // Open holds the hidden Secret, so it keeps its place like Staff does.
    assert_eq!(
        names(body.as_array().unwrap()),
        ["Other", "Voice", "Open", "Text"]
    );

    let all = world.categories(&world.app.admin.token).await;
    assert_eq!(
        names(&all),
        ["Other", "Voice", "Staff", "Open", "Secret", "Text"]
    );
    assert_eq!(
        world.admin_sees(&world.secret_sub).await["parent_id"],
        world.open.as_str()
    );

    let named_hidden = json!({"groups": [{"parent_id": null, "category_ids": [world.staff]}]});
    let [named, unknown] = world
        .ask_twice("PUT", "/categories/order", named_hidden, &world.staff)
        .await;
    assert_eq!(named.0, StatusCode::BAD_REQUEST, "{}", named.1);
    assert_eq!(
        named, unknown,
        "naming a hidden category answers like naming none"
    );
}

#[tokio::test]
async fn an_administrator_still_manages_every_category() {
    let world = World::start("slimm-category-manage-hidden-admin").await;
    let admin = &world.app.admin.token;
    let uri = format!("/categories/{}", world.staff);
    let (status, body) = world
        .app
        .call("PATCH", &uri, admin, Some(json!({"name": "Leads"})))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let inside = json!({"name": "leads-room", "category_id": world.staff});
    let (status, body) = world
        .app
        .call("POST", "/channels", admin, Some(inside))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let (status, _) = world.app.call("DELETE", &uri, admin, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(world.admin_sees(&world.staff).await.is_null());
}

#[tokio::test]
async fn a_category_over_a_hidden_sub_category_is_not_the_managers_to_move_or_delete() {
    let world = World::start("slimm-category-manage-hidden-over").await;
    let listed = world.categories(&world.app.member.token).await;
    let open = listed.iter().find(|c| c["id"] == world.open.as_str());
    let flags = open.map(|c| (c["manageable"].clone(), c["fileable"].clone()));
    assert_eq!(
        flags,
        Some((json!(false), json!(true))),
        "still theirs to file under"
    );
    let other = listed.iter().find(|c| c["name"] == "Other").unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();

    let uri = format!("/categories/{}", world.open);
    let under = json!({"parent_id": other});
    let [named, unknown] = world.ask_twice("PATCH", &uri, under, &world.open).await;
    assert_eq!(named.0, StatusCode::NOT_FOUND, "{}", named.1);
    assert_eq!(named, unknown, "a move answers as for no category");
    let [named, unknown] = world
        .ask_twice("DELETE", &uri, json!({}), &world.open)
        .await;
    assert_eq!(named, unknown);
    assert_eq!(
        world.admin_sees(&world.secret_sub).await["parent_id"],
        world.open.as_str()
    );

    let top: Vec<&Value> = listed
        .iter()
        .filter(|c| c["parent_id"].is_null() && c["id"] != world.open.as_str())
        .map(|c| &c["id"])
        .collect();
    let nest = json!({"groups": [
        {"parent_id": null, "category_ids": top},
        {"parent_id": other, "category_ids": [world.open]},
    ]});
    let (status, body) = world
        .app
        .call(
            "PUT",
            "/categories/order",
            &world.app.member.token,
            Some(nest),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(!body.to_string().contains(&world.secret_sub));
    assert!(
        world.admin_sees(&world.open).await["parent_id"].is_null(),
        "Open stayed put"
    );
}

#[tokio::test]
async fn a_deleted_categorys_id_is_never_handed_back_on_create() {
    let world = World::start("slimm-category-manage-hidden-deleted").await;
    let admin = &world.app.admin.token;
    let gone = create(&world.app, json!({"name": "Old secrets"})).await;
    let (status, _) = world
        .app
        .call("DELETE", &format!("/categories/{gone}"), admin, None)
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    for token in [admin, &world.app.member.token] {
        let again = json!({"id": gone, "name": "anything"});
        let (status, body) = world
            .app
            .call("POST", "/categories", token, Some(again))
            .await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
        assert!(!body.to_string().contains("Old secrets"), "{body}");
    }
}
