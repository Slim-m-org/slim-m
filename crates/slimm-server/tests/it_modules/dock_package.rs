// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module as one file: export from one space, install in another, and
//! everything an import must refuse (decision 0090, section 9).

use axum::body::Body;
use axum::http::{Request, StatusCode};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::support;
use support::module_world::{Install, World, world};
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

const MAX_ARTIFACT_BYTES: usize = 16 * 1024 * 1024;

fn manifest(wasm: &[u8]) -> Value {
    json!({
        "schema": 1,
        "id": "digest",
        "name": "Digest",
        "version": "0.1.0",
        "summary": "posts a digest",
        "artifact": {"kind": "wasm", "path": "module.wasm", "sha256": sha256_hex(wasm)},
        "runtime": {"backend": "wasm"},
        "addon_api": 3,
        "permissions": [{"key": "run", "name": "Run", "description": "run"}],
        "capabilities": ["net.fetch", "kv.store"],
        "network": {"hosts": ["api.example.com"], "local": false},
        "settings": [{"key": "api_key", "type": "secret", "label": "Key", "hosts": ["api.example.com"]}],
        "extension_points": [{"kind": "command", "name": "post", "description": "post", "permission": "run"}]
    })
}

fn package(wasm: &[u8]) -> Value {
    json!({"$slim": "module-package/1", "manifest": manifest(wasm), "artifact": STANDARD.encode(wasm)})
}

async fn admin(w: &World) -> String {
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

async fn call(
    w: &World,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(body.map_or_else(Body::empty, |b| Body::from(b.to_string())))
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

async fn install(w: &World, token: &str, package: Value) -> (StatusCode, Value) {
    let body =
        json!({"package": package, "version": "0.1.0", "approved_host_capabilities": ["kv.store"]});
    call(w, "POST", "/space/dock/packages/install", token, Some(body)).await
}

#[tokio::test]
async fn an_exported_module_installs_in_another_space_as_the_same_module() {
    let wasm = canned_ok_wasm("hello");
    let (a, b) = (world("slimm-pkg-a").await, world("slimm-pkg-b").await);
    let (ta, tb) = (admin(&a).await, admin(&b).await);
    assert_eq!(install(&a, &ta, package(&wasm)).await.0, StatusCode::OK);

    let (status, exported) = call(&a, "GET", "/space/dock/modules/digest/export", &ta, None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, installed) = install(&b, &tb, exported.clone()).await;
    assert_eq!(status, StatusCode::OK, "{installed}");
    assert_eq!(installed["id"], "digest");
    assert_eq!(installed["artifact_sha256"], sha256_hex(&wasm));
    assert_eq!(
        installed["source_repo"], "local/file",
        "a file is never the official source"
    );

    let (_, again) = call(&b, "GET", "/space/dock/modules/digest/export", &tb, None).await;
    assert_eq!(
        again, exported,
        "what comes out of the second space is what went into it"
    );
}

#[tokio::test]
async fn an_export_carries_no_secret_and_no_setting_value() {
    let wasm = canned_ok_wasm("hello");
    let w = world("slimm-pkg-secret").await;
    let token = admin(&w).await;
    install(&w, &token, package(&wasm)).await;
    let put = json!({"values": {"api_key": "hunter2-token"}});
    let (status, _) = call(
        &w,
        "PUT",
        "/space/dock/modules/digest/settings",
        &token,
        Some(put),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (_, exported) = call(&w, "GET", "/space/dock/modules/digest/export", &token, None).await;
    assert!(!exported.to_string().contains("hunter2-token"));
    let mut keys: Vec<&str> = exported
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(keys, ["$slim", "artifact", "manifest"]);
    assert_eq!(
        exported["manifest"]["settings"][0]["key"], "api_key",
        "the schema travels"
    );
}

#[tokio::test]
async fn a_tampered_package_is_refused() {
    let wasm = canned_ok_wasm("hello");
    let w = world("slimm-pkg-tamper").await;
    let token = admin(&w).await;
    let mut swapped = package(&wasm);
    swapped["artifact"] = json!(STANDARD.encode(canned_ok_wasm("evil")));
    let (status, body) = install(&w, &token, swapped).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(w.store.installed_module("digest").await.unwrap().is_none());

    let mut rehashed = package(&wasm);
    rehashed["manifest"]["network"]["hosts"] = json!(["api.example.com", "other.example.com"]);
    let (_, preview) = call(
        &w,
        "POST",
        "/space/dock/packages/preview",
        &token,
        Some(package(&wasm)),
    )
    .await;
    let body = json!({
        "package": rehashed, "version": "0.1.0",
        "approved_host_capabilities": ["kv.store"],
        "reviewed_digest": preview["review_digest"],
    });
    let (status, _) = call(
        &w,
        "POST",
        "/space/dock/packages/install",
        &token,
        Some(body),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "a manifest edited after review is not what was reviewed"
    );
}

#[tokio::test]
async fn a_package_over_the_artifact_ceiling_is_refused() {
    let w = world("slimm-pkg-big").await;
    let token = admin(&w).await;
    let big = vec![0u8; MAX_ARTIFACT_BYTES + 1];
    let (status, body) = install(&w, &token, package(&big)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(body.to_string().contains("too large"), "{body}");
    assert!(w.store.installed_module("digest").await.unwrap().is_none());
}

#[tokio::test]
async fn a_malformed_package_names_what_is_wrong() {
    let wasm = canned_ok_wasm("hello");
    let w = world("slimm-pkg-malformed").await;
    let token = admin(&w).await;
    let mut wrong_schema = package(&wasm);
    wrong_schema["$slim"] = json!("module-package/9");
    let mut no_manifest_id = package(&wasm);
    no_manifest_id["manifest"]["id"] = json!("../etc");
    let mut bad_base64 = package(&wasm);
    bad_base64["artifact"] = json!("%%% not base64");
    for (bad, hint) in [
        (wrong_schema, "unknown package version"),
        (no_manifest_id, "slug"),
        (bad_base64, "base64"),
    ] {
        let (status, body) = install(&w, &token, bad).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
        assert!(body.to_string().contains(hint), "{hint}: {body}");
    }
    let (status, _) = call(
        &w,
        "POST",
        "/space/dock/packages/preview",
        &token,
        Some(json!({"nope": 1})),
    )
    .await;
    assert!(status.is_client_error());
}

#[tokio::test]
async fn the_preview_lists_what_the_module_asks_for() {
    let wasm = canned_ok_wasm("hello");
    let w = world("slimm-pkg-preview").await;
    let token = admin(&w).await;
    let (status, preview) = call(
        &w,
        "POST",
        "/space/dock/packages/preview",
        &token,
        Some(package(&wasm)),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    assert_eq!(preview["capabilities"], json!(["net.fetch", "kv.store"]));
    assert_eq!(preview["network"]["hosts"], json!(["api.example.com"]));
    assert!(
        preview["review_digest"]
            .as_str()
            .is_some_and(|d| d.len() == 64)
    );
    assert!(
        w.store.installed_module("digest").await.unwrap().is_none(),
        "a preview installs nothing"
    );
}

#[tokio::test]
async fn only_someone_who_manages_the_server_can_import_or_export() {
    let wasm = canned_ok_wasm("hello");
    let w = world("slimm-pkg-gate").await;
    let admin_token = admin(&w).await;
    install(&w, &admin_token, package(&wasm)).await;
    assert_eq!(
        install(&w, &w.token, package(&wasm)).await.0,
        StatusCode::FORBIDDEN
    );
    let (status, _) = call(
        &w,
        "GET",
        "/space/dock/modules/digest/export",
        &w.token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        &w,
        "POST",
        "/space/dock/packages/preview",
        &w.token,
        Some(package(&wasm)),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_non_manager_is_refused_before_the_package_is_read() {
    let w = world("slimm-pkg-unread").await;
    for uri in [
        "/space/dock/packages/preview",
        "/space/dock/packages/install",
    ] {
        let request = Request::builder()
            .method("POST")
            .uri(uri)
            .header("authorization", format!("Bearer {}", w.token))
            .header("content-type", "application/json")
            .body(Body::from("{ this is not json"))
            .unwrap();
        let response = w.router.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN, "{uri}");
    }
}

#[tokio::test]
async fn a_file_cannot_take_over_an_id_another_source_installed() {
    let wasm = canned_ok_wasm("hello");
    let w = world("slimm-pkg-clash").await;
    let token = admin(&w).await;
    w.install(Install {
        id: "digest",
        wasm: canned_ok_wasm("official"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let (status, _) = install(&w, &token, package(&wasm)).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_file_module_is_read_and_reapproved_from_what_was_stored() {
    let wasm = canned_ok_wasm("hello");
    let w = world("slimm-pkg-stored").await;
    let token = admin(&w).await;
    install(&w, &token, package(&wasm)).await;

    let (status, manifest) = call(
        &w,
        "GET",
        "/space/dock/modules/digest?source=file",
        &token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{manifest}");
    assert_eq!(manifest["name"], "Digest");

    let body = json!({"version": "0.1.0", "approved_host_capabilities": []});
    let uri = "/space/dock/modules/digest/install?source=file";
    let (status, again) = call(&w, "POST", uri, &token, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{again}");
    assert_eq!(
        again["approved_host_capabilities"],
        json!([]),
        "approval withdrawn"
    );
    assert_eq!(again["source_repo"], "local/file");
}

#[tokio::test]
async fn only_a_module_installed_from_a_file_answers_to_the_file_source() {
    let w = world("slimm-pkg-not-file").await;
    let token = admin(&w).await;
    w.install(Install {
        id: "digest",
        wasm: canned_ok_wasm("official"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let (status, _) = call(
        &w,
        "GET",
        "/space/dock/modules/digest?source=file",
        &token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
