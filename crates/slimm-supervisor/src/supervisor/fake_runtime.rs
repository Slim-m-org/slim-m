// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A container runtime stand-in on a unix socket, for the supervisor's own unit tests.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::extract::State;
use axum::http::{Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

use super::Supervisor;
use crate::checks::Readiness;
use crate::sandbox::{CONNECTOR, INSTANCE, MANAGED_BY, MANAGED_BY_VALUE, ROLE, VOLUME};

#[derive(Default)]
pub struct Docker {
    /// Connector id and whether it runs.
    pub connectors: Vec<(String, bool)>,
    /// What the measuring helper prints for a connector; absent means it prints nothing.
    pub sizes: HashMap<String, u64>,
    pub helper_fails: bool,
    pub stop_fails: HashSet<String>,
    pub stopped: Vec<String>,
    pub network_exists: bool,
    pub image_pull_hangs: bool,
    pub requests: Vec<String>,
    pub probes_now: usize,
    pub probes_most: usize,
}

pub fn labels(id: &str, role: &str) -> Value {
    json!({MANAGED_BY: MANAGED_BY_VALUE, INSTANCE: "inst", CONNECTOR: id, ROLE: role, VOLUME: "1"})
}

fn id_of(name: &str) -> &str {
    name.rsplit_once("inst-").map_or("", |(_, id)| id)
}

fn mux(text: &str) -> Vec<u8> {
    let mut out = vec![1, 0, 0, 0];
    out.extend_from_slice(&(text.len() as u32).to_be_bytes());
    out.extend_from_slice(text.as_bytes());
    out
}

fn isolated(id: &str) -> Value {
    let mut network = crate::sandbox::isolated_network(
        &format!("slimm-n-inst-{id}"),
        labels(id, "network").as_object().cloned().unwrap(),
    );
    network["IPAM"] = json!({"Config": [{"Subnet": "172.30.0.0/16"}]});
    network
}

type Shared = Arc<Mutex<Docker>>;

async fn answer(State(docker): State<Shared>, method: Method, uri: Uri) -> Response {
    let path = uri.path().to_owned();
    docker
        .lock()
        .unwrap()
        .requests
        .push(format!("{method} {path}"));
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    match (method.as_str(), parts.as_slice()) {
        ("GET", ["version"]) => json!({"Version": "28.0.0", "Components": [{"Name": "Engine"}]}).into_json(),
        ("GET", ["info"]) => json!({"CgroupVersion": "2", "MemoryLimit": true, "CpuCfsQuota": true, "PidsLimit": true,
            "SecurityOptions": ["name=apparmor", "name=seccomp,profile=builtin"]}).into_json(),
        ("GET", ["containers", "json"]) => {
            let docker = docker.lock().unwrap();
            let items: Vec<Value> = docker.connectors.iter().map(|(id, running)| {
                json!({"Id": id, "State": if *running {"running"} else {"exited"}, "Labels": labels(id, "connector")})
            }).collect();
            Value::from(items).into_json()
        }
        ("GET", ["containers", name, "json"]) => {
            let known = docker.lock().unwrap().connectors.iter().any(|(id, _)| name.ends_with(id.as_str()));
            match name.starts_with("slimm-c-") && known {
                true => json!({"Config": {"Labels": labels(id_of(name), "connector")}}).into_json(),
                false => StatusCode::NOT_FOUND.into_response(),
            }
        }
        ("GET", ["volumes", name]) => json!({"Labels": labels(id_of(name), "volume")}).into_json(),
        ("GET", ["networks", name]) if name.starts_with("slimm-n-") => {
            match docker.lock().unwrap().network_exists {
                true => isolated(id_of(name)).into_json(),
                false => StatusCode::NOT_FOUND.into_response(),
            }
        }
        ("GET", ["networks", "egress"]) => json!({"Internal": false}).into_json(),
        ("GET", ["networks", name]) if name.starts_with("slimm-probe-") => isolated("probe").into_json(),
        ("GET", ["networks"]) => json!([isolated("c1")]).into_json(),
        ("GET", ["images", ..]) => match docker.lock().unwrap().image_pull_hangs {
            true => StatusCode::NOT_FOUND.into_response(),
            false => json!({"Id": "sha256:abc"}).into_json(),
        },
        ("POST", ["images", "create"]) => {
            tokio::time::sleep(Duration::from_secs(3600)).await;
            StatusCode::OK.into_response()
        }
        ("POST", ["networks", "create"]) => {
            {
                let mut docker = docker.lock().unwrap();
                docker.network_exists = true;
                docker.probes_now += 1;
                docker.probes_most = docker.probes_most.max(docker.probes_now);
            }
            tokio::time::sleep(Duration::from_millis(150)).await;
            StatusCode::CREATED.into_response()
        }
        ("DELETE", ["networks", name]) if name.starts_with("slimm-probe-") => {
            let mut docker = docker.lock().unwrap();
            docker.probes_now = docker.probes_now.saturating_sub(1);
            StatusCode::NO_CONTENT.into_response()
        }
        ("POST", ["containers", "create"]) if docker.lock().unwrap().helper_fails => {
            (StatusCode::INTERNAL_SERVER_ERROR, "busy").into_response()
        }
        ("POST", ["containers", "create"]) => StatusCode::CREATED.into_response(),
        ("POST", ["containers", _, "start"]) => StatusCode::NO_CONTENT.into_response(),
        ("POST", ["containers", _, "wait"]) => json!({"StatusCode": 0}).into_json(),
        ("POST", ["containers", name, "stop"]) => {
            let mut docker = docker.lock().unwrap();
            if docker.stop_fails.contains(id_of(name)) {
                return (StatusCode::INTERNAL_SERVER_ERROR, "stuck").into_response();
            }
            docker.stopped.push(id_of(name).to_owned());
            StatusCode::NO_CONTENT.into_response()
        }
        ("GET", ["containers", name, "logs"]) => {
            let size = docker.lock().unwrap().sizes.get(id_of(name)).copied();
            let text = size.map(|n| format!("2026-01-01T00:00:00Z allocated={n}\n")).unwrap_or_default();
            mux(&text).into_response()
        }
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

trait IntoJson {
    fn into_json(self) -> Response;
}

impl IntoJson for Value {
    fn into_json(self) -> Response {
        axum::Json(self).into_response()
    }
}

pub async fn serve() -> (Arc<Supervisor>, Shared, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("slimm-sup-{}", uuid::Uuid::now_v7().simple()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("runtime.sock");
    let docker: Shared = Default::default();
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let app = Router::new().fallback(answer).with_state(docker.clone());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let env = [
        (
            "SLIMM_SUPERVISOR_SECRET",
            "a-secret-of-at-least-32-characters-x",
        ),
        ("SLIMM_SUPERVISOR_SERVER_URL", "http://server:8080"),
        ("SLIMM_SUPERVISOR_EGRESS_NETWORK", "egress"),
        ("SLIMM_SUPERVISOR_IMAGE", "supervisor:test"),
        ("SLIMM_RUNTIME_SOCKET", socket.to_str().unwrap()),
    ]
    .map(|(k, v)| (k.to_owned(), v.to_owned()))
    .into();
    let mut config = crate::config::Config::from_map(&env).unwrap();
    config.requirements.lsm = false;
    let supervisor = Supervisor::new(config, "inst".to_owned());
    *supervisor.readiness.write().await = Some(Readiness {
        runtime: "docker",
        rootless: false,
        problems: vec![],
        own_image_id: Some("sha256:abc".into()),
    });
    (supervisor, docker, dir)
}
