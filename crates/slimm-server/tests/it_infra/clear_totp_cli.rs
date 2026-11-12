// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `slimm-server clear-totp <username>`: the way back for an operator whose
//! only administrator lost both the authenticator and the recovery codes
//! (decision 0048). Runs the real binary against a migrated database.
#![allow(dead_code)]

use std::process::Command;

use axum::http::StatusCode;
use tower::ServiceExt;

use crate::support;
use crate::totp_support;
use totp_support::{app, enrol_and_confirm, login, member, request};

fn run(path: &str, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_slimm-server"))
        .args(args)
        .env("SLIMM_DATABASE_PATH", path)
        .env("SLIMM_PORT", "0")
        .output()
        .expect("run slimm-server")
}

#[tokio::test]
async fn clear_totp_removes_the_factor_revokes_sessions_and_audits() {
    let (path, guard) = support::TestDbGuard::new("slimm-clear-totp-cli");
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path.clone(),
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    let pool = slimm_server::db::connect(&config).await.unwrap();
    let store = slimm_server::store::Store::new(pool);
    let auth = slimm_server::auth::Auth::new(2).unwrap();
    let app = app(store.clone(), auth.clone());
    let (token, id) = member(&store, &auth, "Ada").await;
    enrol_and_confirm(&app, &token).await;
    assert_eq!(login(&app, "Ada").await.status(), StatusCode::ACCEPTED);

    let missing = run(&path, &["clear-totp", "nobody"]);
    assert!(!missing.status.success(), "an unknown account must fail");

    let output = run(&path, &["clear-totp", "ada"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    assert_eq!(login(&app, "Ada").await.status(), StatusCode::OK);
    let revoked = app
        .clone()
        .oneshot(request("GET", "/me", Some(&token), None))
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::UNAUTHORIZED);

    let rows = sqlx::query_as::<_, (Option<Vec<u8>>, String)>(
        "SELECT actor_id, action FROM moderation_audit_log WHERE subject_id = ?",
    )
    .bind(uuid::Uuid::parse_str(&id).unwrap().as_bytes().to_vec())
    .fetch_all(
        &sqlx::SqlitePool::connect(&format!("sqlite://{path}"))
            .await
            .unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(rows, vec![(None, "totp_cleared".to_owned())]);

    let again = run(&path, &["clear-totp", "ada"]);
    assert!(!again.status.success(), "nothing left to clear must fail");
    drop(guard);
}
