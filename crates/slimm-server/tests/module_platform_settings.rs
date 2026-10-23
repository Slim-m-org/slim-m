// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Module settings (decision 0091): the admin routes, the values a running
//! module receives, and that a secret never leaves the host except in a header.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    DockProvenance, InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec,
    ModulePlatform, ModuleRuntimeLimits, ModuleSettingDef, SettingChoice, SettingKind,
};
use tower::ServiceExt;

mod support;

use support::module_world::{World, world};
use support::wasm_fixtures::{echo_request_wasm, host_call_loop_wasm, sha256_hex};

const MODULE: &str = "scorekeeper";

fn def(key: &str, kind: SettingKind) -> ModuleSettingDef {
    ModuleSettingDef {
        key: key.into(),
        kind,
        label: key.into(),
        help: None,
        default: None,
        min: None,
        max: None,
        choices: Vec::new(),
    }
}

fn schema() -> Vec<ModuleSettingDef> {
    let mut xp = def("xp_per_minute", SettingKind::Int);
    xp.default = Some(json!(5));
    xp.min = Some(0);
    xp.max = Some(100);
    let mut mode = def("mode", SettingKind::Choice);
    mode.choices = vec![SettingChoice {
        value: "quiet".into(),
        label: "Quiet".into(),
    }];
    vec![xp, mode, def("api_key", SettingKind::Secret)]
}

async fn install_with_settings(w: &World, defs: Vec<ModuleSettingDef>) {
    install_module(w, echo_request_wasm(), defs, &[]).await;
}

async fn install_module(w: &World, wasm: Vec<u8>, defs: Vec<ModuleSettingDef>, caps: &[&str]) {
    let sha256 = sha256_hex(&wasm);
    let permissions = [ModulePermissionSpec {
        key: "run",
        name: "Run",
        description: "run it",
    }];
    let points = [ModuleExtensionPointSpec {
        kind: "command",
        name: "run",
        description: None,
        permission: Some("run"),
        command: None,
        language: None,
    }];
    let declared: Vec<String> = caps.iter().map(ToString::to_string).collect();
    let platform = ModulePlatform {
        addon_api: 1,
        settings_schema: defs,
        ..ModulePlatform::default()
    };
    w.store
        .install_module_from_dock(
            InstallModuleRequest {
                id: MODULE,
                name: "Scorekeeper",
                version: "0.1.0",
                artifact_sha256: &sha256,
                approved_capabilities: &declared,
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &permissions,
                extension_points: &points,
            },
            &wasm,
            &DockProvenance {
                host_capabilities: &declared,
                source_repo: None,
                network_hosts: &[],
                local_network_approved: false,
                schedules: &[],
                platform: &platform,
            },
        )
        .await
        .unwrap();
    w.store.set_module_enabled(MODULE, true).await.unwrap();
    let role = w
        .store
        .create_role("runs", Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(w.user.id, role).await.unwrap();
    w.store
        .grant_module_permission(role, MODULE, "run")
        .await
        .unwrap();
}

async fn admin_token(w: &World) -> String {
    let role = w
        .store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = w.store.create_user("root", "Root").await.unwrap();
    w.store.assign_role(admin.id, role).await.unwrap();
    w.store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token
}

async fn call(w: &World, method: &str, token: &str, body: Option<Value>) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(format!("/space/dock/modules/{MODULE}/settings"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.map(|b| b.to_string()).unwrap_or_default()))
        .unwrap();
    let response = w.router.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn entry<'a>(body: &'a Value, key: &str) -> &'a Value {
    body["settings"]
        .as_array()
        .and_then(|all| all.iter().find(|s| s["key"] == key))
        .unwrap_or_else(|| panic!("no setting {key} in {body}"))
}

#[tokio::test]
async fn settings_round_trip_with_defaults_and_clearing() {
    let w = world("slimm-settings-round-trip").await;
    install_with_settings(&w, schema()).await;
    let token = admin_token(&w).await;

    let (status, body) = call(&w, "GET", &token, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(entry(&body, "xp_per_minute")["value"], 5);
    assert!(entry(&body, "mode").get("value").is_none());

    let put = json!({ "values": { "xp_per_minute": 9, "mode": "quiet" } });
    let (status, body) = call(&w, "PUT", &token, Some(put)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(entry(&body, "xp_per_minute")["value"], 9);
    assert_eq!(entry(&body, "mode")["value"], "quiet");

    let clear = json!({ "values": { "xp_per_minute": null } });
    let (_, body) = call(&w, "PUT", &token, Some(clear)).await;
    assert_eq!(entry(&body, "xp_per_minute")["value"], 5);
    assert_eq!(entry(&body, "mode")["value"], "quiet");
}

#[tokio::test]
async fn a_secret_is_never_returned_only_whether_it_is_set() {
    let w = world("slimm-settings-secret").await;
    install_with_settings(&w, schema()).await;
    let token = admin_token(&w).await;

    let (_, body) = call(&w, "GET", &token, None).await;
    assert_eq!(entry(&body, "api_key")["value"], json!({ "set": false }));

    let put = json!({ "values": { "api_key": "hunter2-token" } });
    let (status, body) = call(&w, "PUT", &token, Some(put)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(entry(&body, "api_key")["value"], json!({ "set": true }));
    let (_, again) = call(&w, "GET", &token, None).await;
    assert!(!again.to_string().contains("hunter2-token"));

    let clear = json!({ "values": { "api_key": null } });
    let (_, body) = call(&w, "PUT", &token, Some(clear)).await;
    assert_eq!(entry(&body, "api_key")["value"], json!({ "set": false }));
}

#[tokio::test]
async fn an_invalid_or_unknown_value_is_refused_and_nothing_is_saved() {
    let w = world("slimm-settings-invalid").await;
    install_with_settings(&w, schema()).await;
    let token = admin_token(&w).await;

    for bad in [
        json!({ "xp_per_minute": 101 }),
        json!({ "xp_per_minute": "ten" }),
        json!({ "xp_per_minute": 1.5 }),
        json!({ "mode": "loud" }),
        json!({ "api_key": 7 }),
        json!({ "nope": 1 }),
        json!({ "nope": null }),
    ] {
        let put = json!({ "values": bad });
        let (status, _) = call(&w, "PUT", &token, Some(put)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
    }

    let mixed = json!({ "values": { "xp_per_minute": 20, "mode": "loud" } });
    let (status, _) = call(&w, "PUT", &token, Some(mixed)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (_, body) = call(&w, "GET", &token, None).await;
    assert_eq!(entry(&body, "xp_per_minute")["value"], 5);
}

#[tokio::test]
async fn only_manage_server_may_touch_settings_and_the_module_must_exist() {
    let w = world("slimm-settings-gate").await;
    install_with_settings(&w, schema()).await;
    for method in ["GET", "PUT"] {
        let body = (method == "PUT").then(|| json!({ "values": {} }));
        let (status, _) = call(&w, method, &w.token, body).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{method}");
    }
    let token = admin_token(&w).await;
    let request = Request::builder()
        .uri("/space/dock/modules/ghost/settings")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = w.router.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_running_module_receives_values_over_defaults_and_never_secrets() {
    let w = world("slimm-settings-reach-module").await;
    install_with_settings(&w, schema()).await;
    let token = admin_token(&w).await;

    let seen = w.answer(MODULE).await;
    assert!(seen.contains("'settings':{'xp_per_minute':5}"), "{seen}");

    let put =
        json!({ "values": { "xp_per_minute": 12, "mode": "quiet", "api_key": "hunter2-token" } });
    call(&w, "PUT", &token, Some(put)).await;
    let seen = w.answer(MODULE).await;
    assert!(
        seen.contains("'settings':{'mode':'quiet','xp_per_minute':12}"),
        "{seen}"
    );
    assert!(!seen.contains("hunter2-token") && !seen.contains("api_key"));
}

#[tokio::test]
async fn a_module_without_settings_gets_no_settings_field() {
    let w = world("slimm-settings-none").await;
    install_with_settings(&w, Vec::new()).await;
    let seen = w.answer(MODULE).await;
    assert!(!seen.contains("settings"), "{seen}");
}

#[tokio::test]
async fn uninstalling_removes_the_values() {
    let w = world("slimm-settings-uninstall").await;
    install_with_settings(&w, schema()).await;
    let token = admin_token(&w).await;
    let put = json!({ "values": { "mode": "quiet" } });
    call(&w, "PUT", &token, Some(put)).await;
    assert!(w.store.uninstall_module(MODULE).await.unwrap());
    let left = w.store.module_setting_values(MODULE).await.unwrap();
    assert!(left.is_empty());
}

async fn header_echo_upstream() -> u16 {
    use axum::http::HeaderMap;
    let echo = |headers: HeaderMap| async move {
        headers
            .get("x-api-key")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("none")
            .to_owned()
    };
    let app = axum::Router::new().route("/who", axum::routing::get(echo));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    port
}

fn fetch_with_secret(port: u16, key: &str) -> String {
    json!({
        "capability": "net.fetch",
        "url": format!("http://localhost:{port}/who"),
        "headers": { "x-api-key": { "secret": key } },
    })
    .to_string()
}

async fn install_fetcher(w: &World, port: u16, key: &str) {
    let wasm = host_call_loop_wasm(&fetch_with_secret(port, key), 1);
    install_module(w, wasm, schema(), &["net.fetch"]).await;
    let host = format!("localhost:{port}");
    w.store
        .set_module_network(MODULE, &[host], true)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_stored_secret_reaches_an_approved_host_as_a_header() {
    slimm_server::module_runtime::treat_loopback_as_lan_for_tests(true);
    let w = world("slimm-settings-secret-header").await;
    let port = header_echo_upstream().await;
    install_fetcher(&w, port, "api_key").await;
    let token = admin_token(&w).await;

    let before = w.answer(MODULE).await;
    assert!(before.contains("not set: api_key"), "{before}");

    let put = json!({ "values": { "api_key": "hunter2-token" } });
    call(&w, "PUT", &token, Some(put)).await;
    let after = w.answer(MODULE).await;
    assert!(after.contains("'body':'hunter2-token'"), "{after}");
}

#[tokio::test]
async fn only_a_declared_secret_setting_can_be_named_in_a_header() {
    slimm_server::module_runtime::treat_loopback_as_lan_for_tests(true);
    let w = world("slimm-settings-secret-undeclared").await;
    let port = header_echo_upstream().await;
    install_fetcher(&w, port, "xp_per_minute").await;
    let token = admin_token(&w).await;
    let put = json!({ "values": { "xp_per_minute": 9 } });
    call(&w, "PUT", &token, Some(put)).await;
    let refused = w.answer(MODULE).await;
    assert!(refused.contains("not set: xp_per_minute"), "{refused}");
}

async fn stored_api_key(w: &World) -> Option<String> {
    let pool = sqlx::SqlitePool::connect(&format!("sqlite:{}", w.db_path))
        .await
        .unwrap();
    sqlx::query_scalar("SELECT value FROM module_settings WHERE key = 'api_key'")
        .fetch_optional(&pool)
        .await
        .unwrap()
}

async fn set_raw(w: &World, key: &str, value: &str) {
    let pool = sqlx::SqlitePool::connect(&format!("sqlite:{}", w.db_path))
        .await
        .unwrap();
    sqlx::query("UPDATE module_settings SET value = ? WHERE key = ?")
        .bind(value)
        .bind(key)
        .execute(&pool)
        .await
        .unwrap();
}

async fn put_secret(w: &World, token: &str, value: Value) {
    let put = json!({ "values": { "api_key": value } });
    let (status, _) = call(w, "PUT", token, Some(put)).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_secret_is_sealed_in_the_column_and_still_sent_as_a_header() {
    slimm_server::module_runtime::treat_loopback_as_lan_for_tests(true);
    let w = world("slimm-settings-secret-sealed").await;
    let port = header_echo_upstream().await;
    install_fetcher(&w, port, "api_key").await;
    let token = admin_token(&w).await;
    put_secret(&w, &token, json!("hunter2-token")).await;

    let stored = stored_api_key(&w).await.expect("a row");
    assert!(stored.starts_with("msec1:"), "{stored}");
    assert!(!stored.contains("hunter2-token"), "{stored}");
    let sent = w.answer(MODULE).await;
    assert!(sent.contains("'body':'hunter2-token'"), "{sent}");

    put_secret(&w, &token, Value::Null).await;
    assert!(stored_api_key(&w).await.is_none());
    let cleared = w.answer(MODULE).await;
    assert!(cleared.contains("not set: api_key"), "{cleared}");
}

#[tokio::test]
async fn a_tampered_sealed_secret_is_treated_as_unset() {
    slimm_server::module_runtime::treat_loopback_as_lan_for_tests(true);
    let w = world("slimm-settings-secret-tampered").await;
    let port = header_echo_upstream().await;
    install_fetcher(&w, port, "api_key").await;
    let token = admin_token(&w).await;
    put_secret(&w, &token, json!("hunter2-token")).await;

    let stored = stored_api_key(&w).await.unwrap();
    let flipped = if stored.ends_with('A') { 'B' } else { 'A' };
    let tampered = format!("{}{flipped}", &stored[..stored.len() - 1]);
    set_raw(&w, "api_key", &tampered).await;
    let answer = w.answer(MODULE).await;
    assert!(answer.contains("not set: api_key"), "{answer}");
    assert!(!answer.contains("hunter2-token"), "{answer}");
}

#[tokio::test]
async fn a_plain_stored_secret_is_resealed_on_first_use() {
    slimm_server::module_runtime::treat_loopback_as_lan_for_tests(true);
    let w = world("slimm-settings-secret-legacy").await;
    let port = header_echo_upstream().await;
    install_fetcher(&w, port, "api_key").await;
    let token = admin_token(&w).await;
    put_secret(&w, &token, json!("placeholder")).await;
    set_raw(&w, "api_key", "\"legacy-token\"").await;

    let sent = w.answer(MODULE).await;
    assert!(sent.contains("'body':'legacy-token'"), "{sent}");
    let stored = stored_api_key(&w).await.unwrap();
    assert!(stored.starts_with("msec1:"), "{stored}");
    assert!(!stored.contains("legacy-token"), "{stored}");
}

#[tokio::test]
async fn non_secret_values_stay_plain_and_readable() {
    let w = world("slimm-settings-plain").await;
    install_with_settings(&w, schema()).await;
    let token = admin_token(&w).await;
    let put = json!({ "values": { "mode": "quiet", "api_key": "hunter2-token" } });
    call(&w, "PUT", &token, Some(put)).await;
    let values = w.store.module_setting_values(MODULE).await.unwrap();
    assert_eq!(values.get("mode"), Some(&json!("quiet")));
    assert!(!values.contains_key("api_key"));
}

#[tokio::test]
async fn a_reseal_never_overwrites_a_value_an_admin_saved_since_it_was_read() {
    slimm_server::module_runtime::treat_loopback_as_lan_for_tests(true);
    let w = world("slimm-settings-secret-reseal-race").await;
    let port = header_echo_upstream().await;
    install_fetcher(&w, port, "api_key").await;
    let token = admin_token(&w).await;
    put_secret(&w, &token, json!("placeholder")).await;
    set_raw(&w, "api_key", "\"legacy-token\"").await;

    // The admin saves a new value after the legacy one was read but before it is sealed.
    put_secret(&w, &token, json!("fresh-token")).await;
    let sealed = w
        .store
        .seal_legacy_module_secret(MODULE, "api_key", "\"legacy-token\"")
        .await;
    assert!(!sealed, "a stale read must not seal");
    let sent = w.answer(MODULE).await;
    assert!(sent.contains("'body':'fresh-token'"), "{sent}");
}
