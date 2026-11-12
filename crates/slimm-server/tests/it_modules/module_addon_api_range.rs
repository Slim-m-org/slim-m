// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module whose declared add-on API range excludes this server is never
//! run: not by a member, not on enabling it, and it is turned off at start
//! with the reason (decision 0100).

use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::http::module_compat::disable_incompatible;
use slimm_server::module_runtime::ADDON_API;
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    DockProvenance, InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec,
    ModulePlatform, ModuleRuntimeLimits,
};

use crate::support;
use support::module_world::{World, world};
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

async fn install_ranged(w: &World, id: &str, max: Option<u32>) {
    let wasm = canned_ok_wasm("ran");
    let sha256 = sha256_hex(&wasm);
    let platform = ModulePlatform {
        addon_api: 1,
        addon_api_max: max,
        ..ModulePlatform::default()
    };
    w.store
        .install_module_from_dock(
            InstallModuleRequest {
                id,
                name: "Ranged",
                version: "0.1.0",
                artifact_sha256: &sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[ModulePermissionSpec {
                    key: "run",
                    name: "Run",
                    description: "run it",
                }],
                extension_points: &[ModuleExtensionPointSpec {
                    kind: "command",
                    name: "run",
                    description: None,
                    permission: Some("run"),
                    command: None,
                    language: None,
                }],
            },
            &wasm,
            &DockProvenance {
                manifest_json: None,
                host_capabilities: &[],
                source_repo: None,
                network_hosts: &[],
                local_network_approved: false,
                schedules: &[],
                platform: &platform,
            },
        )
        .await
        .unwrap();
    w.store.set_module_enabled(id, true).await.unwrap();
    let role = w
        .store
        .create_role(&format!("runs-{id}"), Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(w.user.id, role).await.unwrap();
    w.store
        .grant_module_permission(role, id, "run")
        .await
        .unwrap();
}

async fn post(w: &World, uri: &str, body: Value) -> (u16, Value) {
    let request = Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {}", w.token))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let response = tower::ServiceExt::oneshot(w.router.clone(), request)
        .await
        .unwrap();
    let status = response.status().as_u16();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn a_module_outside_its_declared_range_is_never_started() {
    let w = world("slimm-addon-range-run").await;
    install_ranged(&w, "stale", Some(ADDON_API - 1)).await;
    let (status, body) = post(&w, "/modules/stale/commands/run", json!({ "input": "go" })).await;
    assert_eq!(status, 409, "{body}");
    assert!(
        body["error"]
            .as_str()
            .unwrap()
            .contains("update the module")
    );
    let stats = w.store.module_run_stats().await.unwrap();
    assert!(!stats.contains_key("stale"), "the module must not have run");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_start_up_check_turns_off_only_the_modules_outside_their_range() {
    let w = world("slimm-addon-range-sweep").await;
    install_ranged(&w, "stale", Some(ADDON_API - 1)).await;
    install_ranged(&w, "current", Some(ADDON_API)).await;
    install_ranged(&w, "open-ended", None).await;

    disable_incompatible(&w.state).await;

    let enabled = |id: &'static str| {
        let store = w.store.clone();
        async move { store.installed_module(id).await.unwrap().unwrap().enabled }
    };
    assert!(!enabled("stale").await);
    assert!(enabled("current").await);
    assert!(enabled("open-ended").await);
    let health = w.store.module_health().await.unwrap();
    let reason = health["stale"].disabled_reason.clone().unwrap();
    assert!(reason.contains("update the module"), "{reason}");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_admin_cannot_enable_a_module_outside_its_range() {
    let w = world("slimm-addon-range-enable").await;
    install_ranged(&w, "stale", Some(ADDON_API - 1)).await;
    disable_incompatible(&w.state).await;
    let admin = w.store.create_user("boss", "Boss").await.unwrap();
    let role = w
        .store
        .create_role(
            "admin",
            slimm_server::permissions::Permissions::ADMINISTRATOR,
            false,
        )
        .await
        .unwrap();
    w.store.assign_role(admin.id, role).await.unwrap();
    let token = w
        .store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;
    let request = Request::builder()
        .method("POST")
        .uri("/space/dock/modules/stale/enable")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = tower::ServiceExt::oneshot(w.router.clone(), request)
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 409);
    assert!(
        !w.store
            .installed_module("stale")
            .await
            .unwrap()
            .unwrap()
            .enabled
    );
}
