// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space's server log mode (decision 0129): who may switch it, where it
//! shows, the admin download, and that Verbose still never writes a secret.

use axum::Extension;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::http::ServerLogsDir;
use slimm_server::logging::{
    FileLimits, LogMode, LogSettings, Logging, RollingFiles, plan_recent, read_plan, today,
};
use tower::ServiceExt;

use crate::support;
use support::app::{call, general_channel_id, register_id_token, request_bare, router};

#[tokio::test]
async fn an_admin_switches_the_mode_and_every_client_can_read_it() {
    let (store, _guard) = support::new_store("slimm-log-mode").await;
    let (_, admin) = register_id_token(&store, "root").await;
    let (_, member) = register_id_token(&store, "nia").await;
    let app = router(store.clone());

    let (_, settings) = call(&app, "GET", "/space/settings", Some(&admin), None).await;
    assert_eq!(settings["debug_logging"], "off");

    let change = |mode: &str| Some(json!({ "debug_logging": mode }));
    let (status, _) = call(
        &app,
        "PATCH",
        "/space/settings",
        Some(&member),
        change("verbose"),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        &app,
        "PATCH",
        "/space/settings",
        Some(&admin),
        change("loud"),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, body) = call(
        &app,
        "PATCH",
        "/space/settings",
        Some(&admin),
        change("verbose"),
    )
    .await;
    assert_eq!(
        (status, &body["debug_logging"]),
        (StatusCode::OK, &json!("verbose"))
    );
    assert_eq!(store.log_mode().await.unwrap(), LogMode::Verbose);
    let (_, version) = call(&app, "GET", "/version", None, None).await;
    assert_eq!(version["debug_logging"], "verbose");

    call(
        &app,
        "PATCH",
        "/space/settings",
        Some(&admin),
        change("compact"),
    )
    .await;
    let (_, version) = call(&app, "GET", "/version", None, None).await;
    assert_eq!(version["debug_logging"], "compact");
}

async fn download(app: &axum::Router, token: &str) -> (StatusCode, String) {
    let response = app
        .clone()
        .oneshot(request_bare("GET", "/space/server-logs", Some(token)))
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, String::from_utf8(bytes.to_vec()).unwrap())
}

#[tokio::test]
async fn an_admin_downloads_the_newest_lines_as_text_and_it_is_audited() {
    let (store, _guard) = support::new_store("slimm-log-download").await;
    let (_, admin) = register_id_token(&store, "root").await;
    let (_, member) = register_id_token(&store, "nia").await;
    let (dir, _dir_guard) = support::TestDirGuard::new("slimm-log-download-files");
    let mut files = RollingFiles::open(&dir, FileLimits::new(14, 1 << 20)).unwrap();
    files
        .append(b"the call dropped here\n", jiff::Timestamp::now())
        .unwrap();
    files.flush().unwrap();

    let app = router(store.clone()).layer(Extension(ServerLogsDir(Some(dir))));
    assert_eq!(download(&app, &member).await.0, StatusCode::FORBIDDEN);
    assert_eq!(
        download(&app, &admin).await,
        (StatusCode::OK, "the call dropped here\n".to_owned())
    );
    let (_, audit) = call(&app, "GET", "/space/audit-log", Some(&admin), None).await;
    assert!(
        audit.to_string().contains("space.server_logs_download"),
        "{audit}"
    );

    let without_files = router(store).layer(Extension(ServerLogsDir(None)));
    assert_eq!(
        download(&without_files, &admin).await.0,
        StatusCode::NOT_IMPLEMENTED
    );
}

#[tokio::test]
async fn a_second_download_waits_its_turn() {
    let (store, _guard) = support::new_store("slimm-log-one-at-a-time").await;
    let (_, admin) = register_id_token(&store, "root").await;
    let (dir, _dir_guard) = support::TestDirGuard::new("slimm-log-one-at-a-time-files");
    let mut files = RollingFiles::open(&dir, FileLimits::new(14, 1 << 20)).unwrap();
    files.append(b"line\n", jiff::Timestamp::now()).unwrap();
    files.flush().unwrap();
    let app = router(store).layer(Extension(ServerLogsDir(Some(dir))));

    let first = app
        .clone()
        .oneshot(request_bare("GET", "/space/server-logs", Some(&admin)))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(
        download(&app, &admin).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    drop(first);
    assert_eq!(download(&app, &admin).await.0, StatusCode::OK);
}

const PASSWORD: &str = "correct-horse-battery-7731";
const CONTENT: &str = "the private words 9f3e2a";

/// A scoped dispatcher, not a global one: under the single-threaded test runtime
/// every handler runs on this thread, so the stack sees each request's lines.
#[tokio::test]
async fn verbose_never_writes_a_password_a_token_or_what_someone_wrote() {
    let (store, _guard) = support::new_store("slimm-log-redaction").await;
    let (dir, _dir_guard) = support::TestDirGuard::new("slimm-log-redaction-files");
    let settings = LogSettings {
        base_filter: "info".to_owned(),
        dir: Some(dir.clone()),
        limits: FileLimits::new(14, 1 << 24),
    };
    let built = Logging::build(&settings, false);
    let _scope = tracing::dispatcher::set_default(&built.dispatch);
    built.logging.set_mode(LogMode::Verbose);
    let app = router(store.clone());

    let credentials = json!({ "username": "vera", "password": PASSWORD, "device_name": "cli" });
    let (status, registered) = call(
        &app,
        "POST",
        "/auth/register",
        None,
        Some(credentials.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{registered}");
    let (status, signed_in) = call(&app, "POST", "/auth/login", None, Some(credentials)).await;
    assert_eq!(status, StatusCode::OK, "{signed_in}");
    let refresh = json!({ "refresh_token": signed_in["refresh_token"] });
    let (status, refreshed) = call(&app, "POST", "/auth/refresh", None, Some(refresh)).await;
    assert_eq!(status, StatusCode::OK, "{refreshed}");
    let access = refreshed["access_token"].as_str().unwrap().to_owned();
    let channel = general_channel_id(&store).await;
    let message = json!({ "id": uuid::Uuid::now_v7().to_string(), "content": CONTENT });
    let path = format!("/channels/{channel}/messages");
    let (status, _) = call(&app, "POST", &path, Some(&access), Some(message)).await;
    assert_eq!(status, StatusCode::OK);

    built.logging.flush();
    let plan = plan_recent(&dir, 1 << 24, today()).unwrap();
    let text = String::from_utf8(read_plan(&plan).unwrap()).unwrap();
    assert!(
        text.contains("auth: signed in"),
        "Verbose was not on: {text}"
    );
    assert!(text.contains("finished processing request"), "{text}");
    let secrets = [
        PASSWORD,
        CONTENT,
        &access,
        registered["access_token"].as_str().unwrap(),
        registered["refresh_token"].as_str().unwrap(),
        signed_in["access_token"].as_str().unwrap(),
        signed_in["refresh_token"].as_str().unwrap(),
        refreshed["refresh_token"].as_str().unwrap(),
    ];
    for secret in secrets {
        assert!(
            !text.contains(secret),
            "the log carried {secret:?}:\n{text}"
        );
    }
}
