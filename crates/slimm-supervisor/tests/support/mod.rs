// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared by the supervisor's integration tests: a removed-on-drop directory, a running
//! supervisor on a socket in it, and a `supervisor/1` client.
#![allow(dead_code)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::rt::TokioIo;
use serde_json::Value;
use slimm_supervisor::config::Config;
use slimm_supervisor::supervisor::Supervisor;
use tokio::net::UnixStream;

pub const SECRET: &str = "test-secret-0123456789abcdef0123456789";

pub struct TestDir(pub PathBuf);

impl TestDir {
    pub fn new(prefix: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("{prefix}-{}", uuid::Uuid::now_v7().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
        let _ = std::fs::remove_file(socket_for(&self.0));
    }
}

/// A unix socket path must fit in 108 bytes, which a deep `TMPDIR` does not, so sockets
/// live in the short runtime directory under a name derived from their test directory.
pub fn socket_for(dir: &Path) -> PathBuf {
    use sha2::Digest;
    let base = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_owned());
    let hash = sha2::Sha256::digest(dir.as_os_str().as_encoded_bytes());
    let name: String = hash.iter().take(8).map(|b| format!("{b:02x}")).collect();
    Path::new(&base).join(format!("slimm-sup-{name}.sock"))
}

pub fn my_uid() -> u32 {
    std::fs::metadata("/proc/self")
        .map(|m| std::os::unix::fs::MetadataExt::uid(&m))
        .unwrap()
}

/// A config for a supervisor whose socket lives in `dir`; `extra` overrides any key.
pub fn config(dir: &Path, extra: &[(&str, &str)]) -> Config {
    let mut env: HashMap<String, String> = [
        ("SLIMM_SUPERVISOR_SECRET", SECRET.to_owned()),
        (
            "SLIMM_SUPERVISOR_SERVER_URL",
            "http://server:8080".to_owned(),
        ),
        (
            "SLIMM_SUPERVISOR_EGRESS_NETWORK",
            "slimm_connectors_egress".to_owned(),
        ),
        (
            "SLIMM_SUPERVISOR_IMAGE",
            "slimm-supervisor-test:latest".to_owned(),
        ),
        (
            "SLIMM_SUPERVISOR_SOCKET",
            socket_for(dir).display().to_string(),
        ),
        (
            "SLIMM_SUPERVISOR_STATE_DIR",
            dir.join("state").display().to_string(),
        ),
        ("SLIMM_SUPERVISOR_SERVER_UID", my_uid().to_string()),
        (
            "SLIMM_RUNTIME_SOCKET",
            dir.join("no-runtime.sock").display().to_string(),
        ),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v))
    .collect();
    for (k, v) in extra {
        env.insert((*k).to_owned(), (*v).to_owned());
    }
    Config::from_map(&env).unwrap()
}

/// Serves `config` on its socket in the background, with the given instance id.
pub async fn start(config: Config, instance: &str) -> Arc<Supervisor> {
    let socket = config.socket.clone();
    let supervisor = Supervisor::new(config, instance.to_owned());
    let serving = supervisor.clone();
    tokio::spawn(async move {
        if let Err(err) = slimm_supervisor::api::serve(serving).await {
            panic!("the supervisor could not serve: {err}");
        }
    });
    for _ in 0..100 {
        if UnixStream::connect(&socket).await.is_ok() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    supervisor
}

pub struct Client {
    pub socket: PathBuf,
    pub secret: String,
}

impl Client {
    pub fn new(socket: &Path) -> Self {
        Self {
            socket: socket.to_owned(),
            secret: SECRET.to_owned(),
        }
    }

    /// Sends one request; `None` when the supervisor dropped the connection.
    pub async fn send(&self, method: &str, path: &str, body: &str) -> Option<(u16, Value)> {
        let stream = UnixStream::connect(&self.socket).await.ok()?;
        let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
            .await
            .ok()?;
        tokio::spawn(conn);
        let request = hyper::Request::builder()
            .method(method)
            .uri(path)
            .header("host", "supervisor")
            .header("authorization", format!("Bearer {}", self.secret))
            .header("content-type", "application/json")
            .body(Full::new(Bytes::from(body.to_owned())))
            .unwrap();
        let response = sender.send_request(request).await.ok()?;
        let status = response.status().as_u16();
        let bytes = response.into_body().collect().await.ok()?.to_bytes();
        Some((
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        ))
    }

    pub async fn post(&self, path: &str, body: &str) -> (u16, Value) {
        self.send("POST", path, body)
            .await
            .expect("the supervisor answered")
    }

    pub async fn get(&self, path: &str) -> (u16, Value) {
        self.send("GET", path, "")
            .await
            .expect("the supervisor answered")
    }
}

pub fn fixture(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../docs/connectors/supervisor-fixtures")
        .join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

pub mod docker;
