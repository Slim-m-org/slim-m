// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Installing a module that subscribes to pushed events, and reading back
//! what its recorder fixture stored.

use serde_json::Value;
use slimm_server::ids::UserId;
use slimm_server::store::{
    DockProvenance, InstallModuleRequest, ModulePlatform, ModuleRuntimeLimits,
};

use super::module_world::World;
use super::wasm_fixtures::sha256_hex;

/// An event module as an admin approved it.
pub struct EventModule<'a> {
    pub id: &'a str,
    pub wasm: Vec<u8>,
    pub subscribes: &'a [&'a str],
    pub approved: &'a [&'a str],
}

impl World {
    /// Installs and enables the module with its principal; returns the principal.
    pub async fn install_event_module(&self, module: EventModule<'_>) -> UserId {
        let EventModule {
            id,
            wasm,
            subscribes,
            approved,
        } = module;
        let sha256 = sha256_hex(&wasm);
        let approved: Vec<String> = approved.iter().map(ToString::to_string).collect();
        let platform = ModulePlatform {
            addon_api: 1,
            subscriptions: subscribes.iter().map(ToString::to_string).collect(),
            ..ModulePlatform::default()
        };
        self.store
            .install_module_from_dock(
                InstallModuleRequest {
                    id,
                    name: "Listener",
                    version: "0.1.0",
                    artifact_sha256: &sha256,
                    approved_capabilities: &approved,
                    runtime_limits: &ModuleRuntimeLimits::default(),
                    permissions: &[],
                    extension_points: &[],
                },
                &wasm,
                &DockProvenance {
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
        self.store.ensure_module_bot(id, "Listener").await.unwrap()
    }

    /// Every event the recorder fixture stored for `module`, parsed out of the run's request, oldest first.
    pub async fn recorded_events(&self, module: &str) -> Vec<Value> {
        let keys = self.store.module_kv_keys(module, 1000).await.unwrap();
        let mut events = Vec::new();
        for key in keys {
            let raw = self
                .store
                .module_kv_get(module, &key)
                .await
                .unwrap()
                .unwrap();
            let wire: Value = serde_json::from_str(&raw).expect("a recorded request is JSON");
            assert_eq!(wire["command"], "@event");
            let input = wire["input"]
                .as_str()
                .expect("the event rides as the input text");
            events.push(serde_json::from_str(input).expect("the input text is the event JSON"));
        }
        events.sort_by_key(|e: &Value| e["at_ms"].as_i64());
        events
    }

    /// How many `@event` runs the module has had, successful or not.
    pub async fn event_runs(&self, module: &str) -> i64 {
        self.store
            .module_run_stats()
            .await
            .unwrap()
            .get(module)
            .and_then(|stats| stats.iter().find(|s| s.command == "@event"))
            .map_or(0, |s| s.run_count)
    }
}
