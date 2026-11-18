// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A role name no member could read as `@everyone`, `@here` or another role's name, whatever its case.

use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::support;
use support::app::TestApp;

async fn create(app: &TestApp, body: Value) -> (StatusCode, Value) {
    app.call("POST", "/roles", &app.admin.token, Some(body))
        .await
}

async fn rename(app: &TestApp, id: &str, name: &str) -> StatusCode {
    let uri = format!("/roles/{id}");
    let body = json!({ "name": name });
    app.call("PATCH", &uri, &app.admin.token, Some(body))
        .await
        .0
}

#[tokio::test]
async fn a_name_that_reads_as_a_mention_is_refused() {
    let app = TestApp::start("slimm-role-names").await;
    for name in ["everyone", "@Everyone", "HERE", " @here "] {
        let (status, body) = create(&app, json!({ "name": name, "permissions": 0 })).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{name:?}: {body}");
    }
    let (status, _) = create(&app, json!({ "name": "everyone else", "permissions": 0 })).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_second_role_may_not_share_a_name_in_any_case() {
    let app = TestApp::start("slimm-role-names").await;
    let (status, mods) = create(&app, json!({ "name": "Mods", "permissions": 0 })).await;
    assert_eq!(status, StatusCode::OK);
    let mods = mods["id"].as_str().unwrap().to_owned();

    for name in ["mods", "MODS", "@mods"] {
        let (status, body) = create(&app, json!({ "name": name, "permissions": 0 })).await;
        assert_eq!(status, StatusCode::CONFLICT, "{name:?}: {body}");
    }
    let (_, helpers) = create(&app, json!({ "name": "Helpers", "permissions": 0 })).await;
    let helpers = helpers["id"].as_str().unwrap().to_owned();
    assert_eq!(rename(&app, &helpers, "mOdS").await, StatusCode::CONFLICT);
    assert_eq!(
        rename(&app, &helpers, "everyone").await,
        StatusCode::BAD_REQUEST
    );

    assert_eq!(
        rename(&app, &mods, "MODS").await,
        StatusCode::OK,
        "a role may change the case of its own name"
    );
    let (status, retried) = create(
        &app,
        json!({ "id": mods, "name": "MODS", "permissions": 0 }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "an idempotent retry is not a duplicate"
    );
    assert_eq!(retried["id"], mods.as_str());
}

#[tokio::test]
async fn a_role_already_named_like_a_mention_or_another_role_can_still_be_edited() {
    let app = TestApp::start("slimm-role-names").await;
    let no_permissions = slimm_server::permissions::Permissions::NONE;
    let mut ids = Vec::new();
    for name in ["here", "Mods", "mods"] {
        let id = app.store.create_role(name, no_permissions, false).await;
        ids.push(id.unwrap().to_string());
    }

    for (id, name) in ids.iter().zip(["HERE", "Mods", "@mods"]) {
        let uri = format!("/roles/{id}");
        let body = json!({ "name": name, "color": 2 });
        let (status, body) = app.call("PATCH", &uri, &app.admin.token, Some(body)).await;
        assert_eq!(status, StatusCode::OK, "{name:?} resent unchanged: {body}");
    }
    assert_eq!(
        rename(&app, &ids[0], "everyone").await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(rename(&app, &ids[1], "MODS too").await, StatusCode::OK);
    assert_eq!(
        rename(&app, &ids[2], "mods too").await,
        StatusCode::CONFLICT
    );
}
