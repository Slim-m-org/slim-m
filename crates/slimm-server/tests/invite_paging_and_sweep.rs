// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /invites` is paged, and dead invite rows are swept.

use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{json_body, request_authed as request};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

async fn fixture() -> (Store, axum::Router, String, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-invite-paging-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let admin = store.create_account("admin", "Admin", &hash).await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let token = store
        .open_session(admin.id, "d")
        .await
        .unwrap()
        .access_token;
    let app = support::app::builder(store.clone()).auth(auth).router();
    (store, app, token, guard)
}

async fn page(app: &axum::Router, token: &str, query: &str) -> Vec<String> {
    let response = app
        .clone()
        .oneshot(request("GET", &format!("/invites{query}"), token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body: Value = json_body(response).await;
    body.as_array()
        .unwrap()
        .iter()
        .map(|i| i["code"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn invites_come_back_a_page_at_a_time_without_gaps_or_repeats() {
    let (store, app, token, _guard) = fixture().await;
    let admin = store.find_credentials("admin").await.unwrap().unwrap().0;
    for _ in 0..7 {
        store.create_invite(admin, None, None, None).await.unwrap();
    }

    let first = page(&app, &token, "?limit=3").await;
    assert_eq!(first.len(), 3);
    let second = page(&app, &token, &format!("?limit=3&before={}", first[2])).await;
    assert_eq!(second.len(), 3);
    let third = page(&app, &token, &format!("?limit=3&before={}", second[2])).await;
    assert_eq!(third.len(), 1);

    let mut all: Vec<String> = [first, second, third].concat();
    let total = all.len();
    all.sort();
    all.dedup();
    assert_eq!(all.len(), total, "no code appears on two pages");
    assert_eq!(total, 7);
}

#[tokio::test]
async fn an_oversized_limit_is_clamped_and_the_default_is_bounded() {
    let (store, app, token, _guard) = fixture().await;
    let admin = store.find_credentials("admin").await.unwrap().unwrap().0;
    for _ in 0..105 {
        store.create_invite(admin, None, None, None).await.unwrap();
    }
    assert_eq!(page(&app, &token, "").await.len(), 50);
    assert_eq!(page(&app, &token, "?limit=100000").await.len(), 100);
}

#[tokio::test]
async fn the_sweep_drops_long_dead_invites_and_keeps_the_rest() {
    let (store, _app, _token, _guard) = fixture().await;
    let admin = store.find_credentials("admin").await.unwrap().unwrap().0;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;

    let live = store.create_invite(admin, None, None, None).await.unwrap();
    let expired_long_ago = store
        .create_invite(admin, None, None, Some(now - 40 * DAY_MS))
        .await
        .unwrap();
    let expired_recently = store
        .create_invite(admin, None, None, Some(now - DAY_MS))
        .await
        .unwrap();
    let revoked = store.create_invite(admin, None, None, None).await.unwrap();
    store.revoke_invite(&revoked.code, None).await.unwrap();

    // A far-future clock makes "revoked a while ago" true without editing rows.
    assert_eq!(store.sweep_dead_invites_at(now).await.unwrap(), 1);
    assert_eq!(
        store
            .sweep_dead_invites_at(now + 31 * DAY_MS)
            .await
            .unwrap(),
        2
    );

    let left: Vec<String> = store
        .list_invites(None, None, 100)
        .await
        .unwrap()
        .into_iter()
        .map(|i| i.code)
        .collect();
    assert_eq!(left, vec![live.code]);
    assert!(!left.contains(&expired_long_ago.code));
    assert!(!left.contains(&expired_recently.code));
}
