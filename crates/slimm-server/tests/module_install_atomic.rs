// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An installed module's metadata (`installed_modules`) and its artifact
//! bytes (`module_artifacts`) must never disagree: `http::dock::install` now
//! writes both in one transaction (`Store::install_module_with_artifact`),
//! and `http::module_commands::execute_command` compares the approved
//! `artifact_sha256` against the stored artifact's own sha before ever
//! running it. `tests/dock.rs`'s `install_registers_permissions_and_...`
//! already covers the happy path through the HTTP install route; this file
//! is the two failure modes that route was never able to reach on its own.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store, User,
};
use slimm_server::voice::VoiceService;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use std::path::Path;
use std::time::Duration;
use tower::ServiceExt;

mod support;
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

async fn store(name: &str) -> (Store, sqlx::SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

async fn deployment(s: &Store) -> User {
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    s.create_user("nia", "Nia").await.unwrap()
}

/// Installs `code-exec` metadata approving `approved_sha256`'s bytes, one
/// `run` command requiring the `run` permission, then overwrites the artifact
/// row with `stored_wasm` under `stored_sha256`, the divergence the single
/// install transaction now rules out, forced here with a raw write.
async fn install_diverged(
    s: &Store,
    pool: &sqlx::SqlitePool,
    approved_sha256: &str,
    stored_sha256: &str,
    stored_wasm: &[u8],
) {
    let permissions = vec![ModulePermissionSpec {
        key: "run",
        name: "Execute code blocks",
        description: "run a snippet",
    }];
    let extension_points = vec![ModuleExtensionPointSpec {
        kind: "command",
        name: "run",
        description: Some("runs it"),
        permission: Some("run"),
        command: None,
        language: None,
    }];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "code-exec",
            name: "Code Blocks",
            version: "0.2.0",
            artifact_sha256: approved_sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &permissions,
            extension_points: &extension_points,
        },
        stored_wasm,
    )
    .await
    .unwrap();
    sqlx::query("UPDATE module_artifacts SET sha256 = ?, bytes = ? WHERE module_id = 'code-exec'")
        .bind(stored_sha256)
        .bind(stored_wasm)
        .execute(pool)
        .await
        .unwrap();
    s.set_module_enabled("code-exec", true).await.unwrap();
}

async fn grant_run_permission(s: &Store, user: &User) {
    let role = s
        .create_role("coders", Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    s.grant_module_permission(role, "code-exec", "run")
        .await
        .unwrap();
}

fn req_json(method: &str, uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

/// The core defect: `installed_modules.artifact_sha256` says one version was
/// approved, but `module_artifacts` holds a different version's bytes under
/// its own (self-consistent, so `ModuleHost`'s own hash check is a no-op)
/// sha. A run must be refused, not silently executed against the
/// unapproved bytes.
#[tokio::test]
async fn execution_refuses_a_module_whose_stored_artifact_does_not_match_its_approved_sha() {
    let (s, pool, _guard) = store("slimm-module-install-atomic-mismatch").await;
    let member = deployment(&s).await;

    let approved_wasm = canned_ok_wasm("approved");
    let approved_sha256 = sha256_hex(&approved_wasm);
    let unapproved_wasm = canned_ok_wasm("unapproved");
    let unapproved_sha256 = sha256_hex(&unapproved_wasm);
    assert_ne!(approved_sha256, unapproved_sha256);

    install_diverged(
        &s,
        &pool,
        &approved_sha256,
        &unapproved_sha256,
        &unapproved_wasm,
    )
    .await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req_json(
            "POST",
            "/modules/code-exec/commands/run",
            token.access_token.as_str(),
            json!({ "input": "hi" }),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::CONFLICT,
        "a stored artifact that does not match the approved sha must refuse the run, \
         not execute the unapproved bytes"
    );
}

/// A single-connection pool with `max_page_count` capped just past its
/// current size, so a small metadata row fits but a large artifact insert in
/// the same transaction cannot - a deterministic stand-in for a disk-full
/// write failure partway through an install.
async fn size_capped_pool(prefix: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty(prefix);
    let options = SqliteConnectOptions::new()
        .filename(&path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .busy_timeout(Duration::from_secs(5))
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .expect("open pool");
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
        .run(&pool)
        .await
        .expect("migrate");

    let page_count: i64 = sqlx::query_scalar("PRAGMA page_count")
        .fetch_one(&pool)
        .await
        .expect("read page_count");
    sqlx::query(&format!("PRAGMA max_page_count = {}", page_count + 4))
        .execute(&pool)
        .await
        .expect("cap max_page_count");
    (Store::new(pool), guard)
}

/// If the artifact half of an install fails partway through, the metadata
/// half must not have persisted either: a stranded `installed_modules` row
/// pointing at bytes that were never written is exactly the half-installed
/// state the single transaction exists to rule out.
#[tokio::test]
async fn a_failed_artifact_write_leaves_no_half_installed_module() {
    let (s, _guard) = size_capped_pool("slimm-module-install-atomic-rollback").await;

    let oversized_artifact = vec![0xab_u8; 512 * 1024];
    let sha256 = sha256_hex(&oversized_artifact);
    let result = s
        .install_module_with_artifact(
            InstallModuleRequest {
                id: "too-big",
                name: "Too Big",
                version: "1.0.0",
                artifact_sha256: &sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[],
                extension_points: &[],
            },
            &oversized_artifact,
        )
        .await;
    assert!(
        result.is_err(),
        "an artifact write past the database's size cap should fail, not silently truncate"
    );
    assert!(
        s.installed_module("too-big").await.unwrap().is_none(),
        "a failed artifact write must leave no half-installed module behind"
    );
}
