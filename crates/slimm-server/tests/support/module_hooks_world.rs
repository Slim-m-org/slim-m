// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Installing a module that hooks into messages or permission checks, with a
//! canned wasm reply, and sending through the real routes.

use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::store::{
    DockProvenance, HookDecl, HookKind, InstallModuleRequest, ModulePlatform, ModuleRuntimeLimits,
};

use super::module_world::World;
use super::wasm_fixtures::{canned_raw_wasm, sha256_hex};

/// A module whose every hook answers with `reply`, as the module's `output` text.
pub fn answering(reply: &Value) -> Vec<u8> {
    let response = json!({ "ok": true, "output": reply.to_string() });
    canned_raw_wasm(response.to_string().as_bytes())
}

/// A module that traps the moment it is run.
pub fn trapping() -> Vec<u8> {
    wat::parse_str(
        r#"(module
            (memory (export "memory") 1)
            (func (export "alloc") (param $len i32) (result i32) (i32.const 0))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                unreachable))"#,
    )
    .expect("trapping wasm fixture must parse")
}

/// A module that rewrites the message to its own input, with each quote and backslash turned
/// into an apostrophe, so what it was sent is what gets stored.
pub fn rewrites_to_its_input() -> Vec<u8> {
    let prefix = r#"{"ok":true,"output":"{\"content\":\""#;
    let plen = prefix.len();
    let data = prefix.replace('\\', "\\\\").replace('"', "\\\"");
    let text = format!(
        r#"(module
            (memory (export "memory") 1)
            (data (i32.const 1024) "{data}")
            (func (export "alloc") (param $len i32) (result i32) (i32.const 8192))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (local $i i32) (local $b i32) (local $out i32)
                (local.set $out (i32.add (i32.const 1024) (i32.const {plen})))
                (block $done
                    (loop $loop
                        (br_if $done (i32.ge_u (local.get $i) (local.get $in_len)))
                        (local.set $b (i32.load8_u (i32.add (local.get $in_ptr) (local.get $i))))
                        (if (i32.or (i32.eq (local.get $b) (i32.const 34))
                                    (i32.eq (local.get $b) (i32.const 92)))
                            (then (local.set $b (i32.const 39))))
                        (i32.store8 (i32.add (local.get $out) (local.get $i)) (local.get $b))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $loop)))
                (i32.store8 (i32.add (local.get $out) (local.get $in_len)) (i32.const 92))
                (i32.store8 (i32.add (local.get $out) (i32.add (local.get $in_len) (i32.const 1))) (i32.const 34))
                (i32.store8 (i32.add (local.get $out) (i32.add (local.get $in_len) (i32.const 2))) (i32.const 125))
                (i32.store8 (i32.add (local.get $out) (i32.add (local.get $in_len) (i32.const 3))) (i32.const 34))
                (i32.store8 (i32.add (local.get $out) (i32.add (local.get $in_len) (i32.const 4))) (i32.const 125))
                (i64.or (i64.shl (i64.const 1024) (i64.const 32))
                    (i64.extend_i32_u (i32.add (local.get $in_len) (i32.const {tail}))))))"#,
        tail = plen + 5
    );
    wat::parse_str(&text).expect("rewrites-to-input wasm fixture must parse")
}

pub fn interceptor(hook: &str, phase: &str, reads: &[&str]) -> HookDecl {
    HookDecl {
        kind: HookKind::Interceptor,
        hook: hook.into(),
        phase: phase.into(),
        reads: reads.iter().map(ToString::to_string).collect(),
    }
}

pub fn permission_hook(action: &str) -> HookDecl {
    HookDecl {
        kind: HookKind::Permission,
        hook: action.into(),
        phase: String::new(),
        reads: Vec::new(),
    }
}

pub struct HookModule<'a> {
    pub id: &'a str,
    pub wasm: Vec<u8>,
    pub hooks: Vec<HookDecl>,
}

impl World {
    /// Installs and enables a module with `hooks`, approved for the capability each kind needs.
    pub async fn install_hook_module(&self, module: HookModule<'_>) {
        let HookModule { id, wasm, hooks } = module;
        let sha256 = sha256_hex(&wasm);
        let mut approved: Vec<String> = Vec::new();
        if hooks.iter().any(|h| h.kind == HookKind::Interceptor) {
            approved.push("interceptors".into());
        }
        if hooks.iter().any(|h| h.kind == HookKind::Permission) {
            approved.push("permission.hook".into());
        }
        let platform = ModulePlatform {
            addon_api: 3,
            hooks,
            ..ModulePlatform::default()
        };
        self.store
            .install_module_from_dock(
                InstallModuleRequest {
                    id,
                    name: id,
                    version: "0.1.0",
                    artifact_sha256: &sha256,
                    approved_capabilities: &approved,
                    runtime_limits: &ModuleRuntimeLimits::default(),
                    permissions: &[],
                    extension_points: &[],
                },
                &wasm,
                &DockProvenance {
                    manifest_json: None,
                    host_capabilities: &approved,
                    source_repo: None,
                    network_hosts: &[],
                    local_network_approved: false,
                    schedules: &[],
                    platform: &platform,
                },
            )
            .await
            .unwrap();
        self.store.set_module_enabled(id, true).await.unwrap();
    }

    /// Posts `content` to `channel` as `nia`; the status and the JSON body.
    pub async fn say(&self, channel: ChannelId, content: &str) -> (u16, Value) {
        let body = json!({ "id": MessageId::generate().to_string(), "content": content });
        self.call_json("POST", &format!("/channels/{channel}/messages"), body)
            .await
    }

    /// Edits message `id` as `nia`.
    pub async fn edit(&self, channel: ChannelId, id: &str, content: &str) -> (u16, Value) {
        self.call_json(
            "PATCH",
            &format!("/channels/{channel}/messages/{id}"),
            json!({ "content": content }),
        )
        .await
    }

    pub async fn call_json(&self, method: &str, uri: &str, body: Value) -> (u16, Value) {
        let request = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.token))
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let response = tower::ServiceExt::oneshot(self.router.clone(), request)
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

    /// How many times `command` has run for `module`, as the run stats count them.
    pub async fn runs_of(&self, module: &str, command: &str) -> i64 {
        let stats = self.store.module_run_stats().await.unwrap();
        stats
            .get(module)
            .and_then(|all| all.iter().find(|s| s.command == command))
            .map_or(0, |s| s.run_count)
    }
}
