// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A route that changes several fields changes all of them or none: a write that
//! fails part-way must not leave the first fields applied with no event sent.

use axum::http::StatusCode;
use serde_json::json;
use sqlx::{Connection, Executor};
use tower::ServiceExt;

use crate::support;
use slimm_server::config::Config;
use slimm_server::store::Store;
use support::TestDbGuard;
use support::overwrite_harness::{app, general_channel_id, register, request};

async fn new_store(prefix: &str) -> (Store, String, TestDbGuard) {
    let (path, guard) = TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path.clone(),
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = slimm_server::db::connect(&config).await.unwrap();
    (Store::new(pool), path, guard)
}

async fn break_updates(db_path: &str, trigger: &str) {
    let mut conn = sqlx::SqliteConnection::connect(&format!("sqlite://{db_path}"))
        .await
        .unwrap();
    conn.execute(trigger).await.unwrap();
}

#[tokio::test]
async fn a_channel_update_that_fails_part_way_changes_nothing() {
    let (store, path, _guard) = new_store("slimm-atomic-channel").await;
    let (token, _) = register(&store, "root").await;
    let channel = general_channel_id(&store).await;
    break_updates(
        &path,
        "CREATE TRIGGER boom BEFORE UPDATE OF slow_mode_seconds ON channels \
         WHEN NEW.slow_mode_seconds != OLD.slow_mode_seconds \
         BEGIN SELECT RAISE(ABORT, 'boom'); END",
    )
    .await;
    let router = app(store.clone());

    let response = router
        .oneshot(request(
            "PATCH",
            &format!("/channels/{channel}"),
            Some(&token),
            Some(json!({ "name": "renamed", "slow_mode_seconds": 5 })),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let after = store.list_channels().await.unwrap();
    assert_eq!(after[0].name, "general", "the rename must not have stuck");
}

#[tokio::test]
async fn a_role_update_that_fails_part_way_changes_nothing() {
    let (store, path, _guard) = new_store("slimm-atomic-role").await;
    let (token, _) = register(&store, "root").await;
    let role = store
        .create_role("mods", slimm_server::permissions::Permissions::NONE, false)
        .await
        .unwrap();
    break_updates(
        &path,
        "CREATE TRIGGER boom BEFORE UPDATE OF hoist ON roles \
         WHEN NEW.hoist != OLD.hoist \
         BEGIN SELECT RAISE(ABORT, 'boom'); END",
    )
    .await;
    let router = app(store.clone());

    let response = router
        .oneshot(request(
            "PATCH",
            &format!("/roles/{role}"),
            Some(&token),
            Some(json!({ "name": "renamed", "hoist": true })),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let after = store.role(role).await.unwrap().unwrap();
    assert_eq!(after.name, "mods", "the rename must not have stuck");
}
