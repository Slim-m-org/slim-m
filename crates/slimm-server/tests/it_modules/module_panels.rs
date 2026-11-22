// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Dock panels (decision 0131): `GET /modules/panels` offers a module's
//! `panel` extension point only to a member holding its permission, only for
//! a module at add-on API 6 or higher, and the panel's command runs through
//! the ordinary per-caller command route.

use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    DockProvenance, InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec,
    ModulePlatform, ModuleRuntimeLimits,
};
use tower::ServiceExt;

use crate::support;
use support::module_world::{World, world};
use support::wasm_fixtures::{canned_raw_wasm, sha256_hex};

const SCENE: &str = r#"{"$slim":"scene/1","width":4,"height":4,"ops":[]}"#;

async fn install_panel(w: &World, addon_api: u32) {
    let wasm = canned_raw_wasm(
        json!({ "ok": true, "output": SCENE })
            .to_string()
            .as_bytes(),
    );
    let sha256 = sha256_hex(&wasm);
    let platform = ModulePlatform {
        addon_api,
        ..ModulePlatform::default()
    };
    let points = [
        ModuleExtensionPointSpec {
            kind: "command",
            name: "board",
            description: None,
            permission: Some("use"),
            command: None,
            language: None,
        },
        ModuleExtensionPointSpec {
            kind: "panel",
            name: "Board",
            description: Some("A board beside the chat"),
            permission: Some("use"),
            command: Some("board"),
            language: None,
        },
    ];
    w.store
        .install_module_from_dock(
            InstallModuleRequest {
                id: "board",
                name: "Board",
                version: "0.1.0",
                artifact_sha256: &sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[ModulePermissionSpec {
                    key: "use",
                    name: "Use the board",
                    description: "open it",
                }],
                extension_points: &points,
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
    w.store.set_module_enabled("board", true).await.unwrap();
}

async fn grant_use(w: &World) {
    let role = w
        .store
        .create_role("board-users", Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(w.user.id, role).await.unwrap();
    w.store
        .grant_module_permission(role, "board", "use")
        .await
        .unwrap();
}

async fn call(w: &World, method: &str, uri: &str, body: Option<Value>) -> (u16, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {}", w.token));
    let body = match body {
        Some(body) => {
            request = request.header("content-type", "application/json");
            Body::from(body.to_string())
        }
        None => Body::empty(),
    };
    let response = w
        .router
        .clone()
        .oneshot(request.body(body).unwrap())
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

async fn panels(w: &World) -> Value {
    let (status, body) = call(w, "GET", "/modules/panels", None).await;
    assert_eq!(status, 200, "{body}");
    body
}

#[tokio::test]
async fn a_deployment_with_no_panel_module_lists_no_panels() {
    let w = world("slimm-panels-none").await;
    assert_eq!(panels(&w).await, json!([]));
}

#[tokio::test]
async fn a_permission_holder_is_offered_the_panel_with_its_name() {
    let w = world("slimm-panels-offered").await;
    install_panel(&w, 6).await;
    assert_eq!(panels(&w).await, json!([]), "no permission, no entry");

    grant_use(&w).await;
    assert_eq!(
        panels(&w).await,
        json!([{
            "module_id": "board",
            "command": "board",
            "name": "Board",
            "description": "A board beside the chat",
            "module": {
                "name": "Board",
                "verified": true,
                "capabilities": [],
                "network_hosts": []
            }
        }])
    );

    w.store.set_module_enabled("board", false).await.unwrap();
    assert_eq!(
        panels(&w).await,
        json!([]),
        "a disabled module offers nothing"
    );
}

#[tokio::test]
async fn a_module_below_level_6_never_offers_a_panel() {
    let w = world("slimm-panels-old-level").await;
    install_panel(&w, 5).await;
    grant_use(&w).await;
    assert_eq!(panels(&w).await, json!([]));
}

#[tokio::test]
async fn the_panel_runs_through_the_command_route_for_its_holder_only() {
    let w = world("slimm-panels-run").await;
    install_panel(&w, 6).await;
    let run = json!({ "input": r#"{"action":"refresh","state":""}"# });

    let (status, _) = call(
        &w,
        "POST",
        "/modules/board/commands/board",
        Some(run.clone()),
    )
    .await;
    assert_eq!(status, 403);

    grant_use(&w).await;
    let (status, body) = call(&w, "POST", "/modules/board/commands/board", Some(run)).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body, json!({ "ok": true, "output": SCENE }));
}
