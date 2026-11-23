// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A minimal `supervisor/1` stand-in, so the host-run routes (decision 0134) answer their
//! documented 200s here; `tests/it_modules/connectors/host_run.rs` drives their behaviour.

use std::path::{Path, PathBuf};

use axum::Router;
use axum::routing::{get, post};
use serde_json::{Value, json};
use tokio::net::UnixListener;

pub const SECRET: &str = "contract-supervisor-secret-0123456789ab";
pub const HOST_RUN_ID: &str = "media-relay";

/// Removes the socket when the contract run ends.
pub struct Guard(pub PathBuf);

impl Drop for Guard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

pub async fn spawn() -> Guard {
    let base = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_owned());
    let socket = Path::new(&base).join(format!(
        "slimm-contract-sup-{}.sock",
        &uuid::Uuid::now_v7().simple().to_string()[16..]
    ));
    let listener = UnixListener::bind(&socket).unwrap();
    let ok = || async { axum::Json(json!({"v": 1})) };
    let router = Router::new()
        .route("/v1/hello", get(|| async {
            axum::Json(json!({"v": 1, "protocol": "supervisor/1", "version": "test", "runtime": "docker",
                "rootless": false, "ready": true, "problems": [], "registries": ["ghcr.io/slim-m-org/"],
                "ceilings": {"max_connectors": 8, "max_memory_mib": 512, "max_cpus": 1.0, "max_pids": 256}, "connectors": 0}))
        }))
        .route("/v1/connectors", get(|| async { axum::Json(json!({"v": 1, "connectors": []})) }))
        .route("/v1/connectors/{id}/logs", get(|| async {
            axum::Json(json!({"v": 1, "lines": [{"ts": "2026-11-22T10:00:00Z", "stream": "stdout", "text": "connected"}]}))
        }))
        .route("/v1/connectors/{id}/{verb}", post(ok));
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    Guard(socket)
}

/// A connector that asks the host to run its image.
pub fn host_run_manifest() -> Value {
    json!({
        "schema": 1, "id": HOST_RUN_ID, "name": "Media Relay", "version": "0.1.0",
        "summary": "a host-run connector", "provider": "connector", "addon_api": 7,
        "connector": {"permissions": ["send_messages"], "host_run": {
            "image": "ghcr.io/slim-m-org/media-relay@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "egress": [{"host": "api.example.com", "port": 443}], "volume": true, "limits": {"memory_mib": 64}
        }}
    })
}
