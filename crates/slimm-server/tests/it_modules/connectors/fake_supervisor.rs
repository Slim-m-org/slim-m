// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A `supervisor/1` stand-in on a unix socket: it records every call, keeps container
//! states in memory, and can play a down runtime or a policy refusal.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::{Path as UrlPath, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde_json::{Value, json};
use tokio::net::UnixListener;

pub const SECRET: &str = "fake-supervisor-secret-0123456789abcdef";

#[derive(Default)]
pub struct Inner {
    /// `(verb, run id, body)` for every authorized call.
    pub calls: Vec<(String, String, Value)>,
    /// Run id to `{"state", "finished_at", "exit_code"}`.
    pub containers: BTreeMap<String, Value>,
    pub runtime_down: bool,
    pub refuse_create: Option<(String, String)>,
    pub hello: Option<Value>,
}

#[derive(Clone, Default)]
pub struct Fake(pub Arc<Mutex<Inner>>);

impl Fake {
    pub fn calls(&self, verb: &str) -> Vec<(String, Value)> {
        let inner = self.0.lock().unwrap();
        inner
            .calls
            .iter()
            .filter(|c| c.0 == verb)
            .map(|c| (c.1.clone(), c.2.clone()))
            .collect()
    }

    pub fn set_state(&self, id: &str, state: &str, finished_at: &str) {
        let mut inner = self.0.lock().unwrap();
        inner.containers.insert(
            id.to_owned(),
            json!({"state": state, "finished_at": finished_at, "exit_code": 1}),
        );
    }

    pub fn state(&self, id: &str) -> Option<String> {
        let inner = self.0.lock().unwrap();
        inner
            .containers
            .get(id)
            .and_then(|c| c["state"].as_str().map(str::to_owned))
    }

    pub fn with<R>(&self, f: impl FnOnce(&mut Inner) -> R) -> R {
        f(&mut self.0.lock().unwrap())
    }
}

/// A short socket path: a unix socket must fit in 108 bytes, which a deep temp dir may not.
pub fn socket_path() -> PathBuf {
    let base = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_owned());
    Path::new(&base).join(format!(
        "slimm-fake-sup-{}.sock",
        &uuid::Uuid::now_v7().simple().to_string()[16..]
    ))
}

/// Removes the socket file when the test ends.
pub struct SocketGuard(pub PathBuf);

impl Drop for SocketGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

pub async fn serve(fake: Fake, socket: &Path) -> tokio::task::JoinHandle<()> {
    let _ = std::fs::remove_file(socket);
    let listener = UnixListener::bind(socket).unwrap();
    let router = Router::new()
        .route("/v1/hello", get(hello))
        .route("/v1/connectors", get(list))
        .route("/v1/connectors/{id}/logs", get(logs))
        .route("/v1/connectors/{id}/{verb}", post(verb))
        .with_state(fake);
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() })
}

fn error(status: StatusCode, code: &str, detail: &str) -> Response {
    (
        status,
        axum::Json(json!({"v": 1, "error": code, "detail": detail})),
    )
        .into_response()
}

fn authorized(headers: &HeaderMap) -> bool {
    headers.get("authorization").and_then(|v| v.to_str().ok()) == Some(&format!("Bearer {SECRET}"))
}

async fn hello(State(fake): State<Fake>, headers: HeaderMap) -> Response {
    if !authorized(&headers) {
        return error(StatusCode::UNAUTHORIZED, "unauthorized", "wrong secret");
    }
    let inner = fake.0.lock().unwrap();
    if inner.runtime_down {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "runtime_unavailable",
            "cannot reach the container runtime",
        );
    }
    let hello = inner.hello.clone().unwrap_or_else(|| {
        json!({"v": 1, "protocol": "supervisor/1", "version": "test", "runtime": "docker", "rootless": false,
               "ready": true, "problems": [], "registries": ["ghcr.io/slim-m-org/"],
               "ceilings": {"max_connectors": 8, "max_memory_mib": 512, "max_cpus": 1.0, "max_pids": 256, "max_volume_mib": 1024},
               "connectors": inner.containers.len()})
    });
    axum::Json(hello).into_response()
}

async fn list(State(fake): State<Fake>, headers: HeaderMap) -> Response {
    if !authorized(&headers) {
        return error(StatusCode::UNAUTHORIZED, "unauthorized", "wrong secret");
    }
    let mut inner = fake.0.lock().unwrap();
    inner
        .calls
        .push(("list".into(), String::new(), Value::Null));
    if inner.runtime_down {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "runtime_unavailable",
            "cannot reach the container runtime",
        );
    }
    let connectors: Vec<Value> = inner
        .containers
        .iter()
        .map(|(id, c)| json!({"id": id, "state": c["state"], "exit_code": c["exit_code"], "oom_killed": false,
                              "started_at": "2026-11-22T10:00:00Z", "finished_at": c["finished_at"], "image": "img",
                              "volume_bytes": c.get("volume_bytes"), "volume_over_limit": c.get("volume_over_limit").unwrap_or(&json!(false))}))
        .collect();
    axum::Json(json!({"v": 1, "connectors": connectors})).into_response()
}

async fn logs(
    State(fake): State<Fake>,
    headers: HeaderMap,
    UrlPath(id): UrlPath<String>,
) -> Response {
    if !authorized(&headers) {
        return error(StatusCode::UNAUTHORIZED, "unauthorized", "wrong secret");
    }
    if fake.0.lock().unwrap().runtime_down {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "runtime_unavailable",
            "cannot reach the container runtime",
        );
    }
    if !fake.0.lock().unwrap().containers.contains_key(&id) {
        return error(StatusCode::NOT_FOUND, "not_found", "no such connector");
    }
    let lines = json!([{"ts": "2026-11-22T10:00:00Z", "stream": "stdout", "text": "connected"}]);
    axum::Json(json!({"v": 1, "lines": lines})).into_response()
}

async fn verb(
    State(fake): State<Fake>,
    headers: HeaderMap,
    UrlPath((id, verb)): UrlPath<(String, String)>,
    body: String,
) -> Response {
    if !authorized(&headers) {
        return error(StatusCode::UNAUTHORIZED, "unauthorized", "wrong secret");
    }
    let body: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    let mut inner = fake.0.lock().unwrap();
    inner.calls.push((verb.clone(), id.clone(), body.clone()));
    if inner.runtime_down {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "runtime_unavailable",
            "cannot reach the container runtime",
        );
    }
    match verb.as_str() {
        "create" => {
            if let Some((code, detail)) = inner.refuse_create.clone() {
                return error(StatusCode::FORBIDDEN, &code, &detail);
            }
            inner.containers.entry(id).or_insert_with(
                || json!({"state": "created", "finished_at": null, "exit_code": null}),
            );
        }
        "start" => match inner.containers.get_mut(&id) {
            Some(c) => c["state"] = json!("running"),
            None => return error(StatusCode::NOT_FOUND, "not_found", "no such connector"),
        },
        "stop" => match inner.containers.get_mut(&id) {
            Some(c) => c["state"] = json!("exited"),
            None => return error(StatusCode::NOT_FOUND, "not_found", "no such connector"),
        },
        "remove" => {
            inner.containers.remove(&id);
        }
        _ => return error(StatusCode::NOT_FOUND, "not_found", "no such route"),
    }
    axum::Json(json!({"v": 1})).into_response()
}
