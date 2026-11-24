// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The server's half of `supervisor/1` (decision 0134): JSON over the supervisor's unix
//! socket with the bearer secret. Hand-written, like the rest of the wire contract.

use std::path::PathBuf;
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Bytes;
use hyper_util::rt::TokioIo;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::net::UnixStream;

use crate::store::EgressHost;

const TIMEOUT: Duration = Duration::from_secs(120);
const MAX_ANSWER: usize = 1024 * 1024;

/// Why a supervisor call did not succeed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SupervisorError {
    /// The supervisor or its runtime cannot be reached; retry later.
    Unavailable(String),
    /// The supervisor answered with one of its codes; `policy` and `limit` are never retried.
    Refused { code: String, detail: String },
}

impl SupervisorError {
    pub fn is_policy(&self) -> bool {
        matches!(self, Self::Refused { code, .. } if code == "policy" || code == "limit")
    }

    pub fn detail(&self) -> &str {
        match self {
            Self::Unavailable(detail) | Self::Refused { detail, .. } => detail,
        }
    }
}

/// The create body: the whole of what the server may choose.
#[derive(Serialize)]
pub struct CreateBody<'a> {
    pub image: &'a str,
    pub env: std::collections::BTreeMap<&'static str, String>,
    pub limits: Limits,
    pub egress: &'a [EgressHost],
    pub egress_private: bool,
    pub volume: bool,
}

#[derive(Serialize, Default)]
pub struct Limits {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_mib: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpus: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pids: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volume_mib: Option<i64>,
}

/// One labelled connector as the supervisor lists it.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct Listed {
    pub id: String,
    pub state: String,
    #[serde(default)]
    pub exit_code: Option<i64>,
    #[serde(default)]
    pub oom_killed: bool,
    #[serde(default)]
    pub started_at: Option<String>,
    #[serde(default)]
    pub finished_at: Option<String>,
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default)]
    pub volume_bytes: Option<u64>,
    /// The supervisor stopped it because its data volume is over the approved ceiling.
    #[serde(default)]
    pub volume_over_limit: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct LogLine {
    pub ts: String,
    pub stream: String,
    pub text: String,
}

#[derive(Clone)]
pub struct SupervisorClient {
    socket: PathBuf,
    secret: String,
    deployment: std::sync::Arc<std::sync::OnceLock<String>>,
}

impl std::fmt::Debug for SupervisorClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SupervisorClient")
            .field("socket", &self.socket)
            .finish_non_exhaustive()
    }
}

/// The protocol this server speaks; the supervisor refuses unknown fields, so it upgrades first.
pub const PROTOCOL: &str = "supervisor/1";

/// Turns a supervisor on another protocol into a message the admin sees in the host's health.
fn check_protocol(hello: &Value) -> Result<(), SupervisorError> {
    match hello.get("protocol").and_then(Value::as_str) {
        Some(PROTOCOL) => Ok(()),
        other => Err(SupervisorError::Unavailable(format!(
            "the connector supervisor speaks {}, this server needs {PROTOCOL}; upgrade the supervisor before the server",
            other.unwrap_or("no protocol")
        ))),
    }
}

impl SupervisorClient {
    pub fn new(socket: impl Into<PathBuf>, secret: String) -> Self {
        Self {
            socket: socket.into(),
            secret,
            deployment: Default::default(),
        }
    }

    /// Names this deployment on every call; the supervisor binds to the first one it hears.
    pub fn set_deployment(&self, deployment: String) {
        let _ = self.deployment.set(deployment);
    }

    pub async fn hello(&self) -> Result<Value, SupervisorError> {
        let hello = self.call("GET", "/v1/hello", None).await?;
        check_protocol(&hello)?;
        Ok(hello)
    }

    pub async fn list(&self) -> Result<Vec<Listed>, SupervisorError> {
        let answer = self.call("GET", "/v1/connectors", None).await?;
        serde_json::from_value(answer.get("connectors").cloned().unwrap_or(Value::Null)).map_err(
            |err| {
                SupervisorError::Unavailable(format!("the supervisor's list did not parse: {err}"))
            },
        )
    }

    pub async fn logs(&self, id: &str, tail: u32) -> Result<Vec<LogLine>, SupervisorError> {
        let answer = self
            .call(
                "GET",
                &format!("/v1/connectors/{id}/logs?tail={tail}"),
                None,
            )
            .await?;
        serde_json::from_value(answer.get("lines").cloned().unwrap_or(Value::Null)).map_err(|err| {
            SupervisorError::Unavailable(format!("the supervisor's logs did not parse: {err}"))
        })
    }

    pub async fn create(&self, id: &str, body: &CreateBody<'_>) -> Result<(), SupervisorError> {
        let body = serde_json::to_vec(body).unwrap_or_default();
        self.call("POST", &format!("/v1/connectors/{id}/create"), Some(body))
            .await
            .map(drop)
    }

    pub async fn start(&self, id: &str) -> Result<(), SupervisorError> {
        self.call(
            "POST",
            &format!("/v1/connectors/{id}/start"),
            Some(b"{}".to_vec()),
        )
        .await
        .map(drop)
    }

    pub async fn stop(&self, id: &str) -> Result<(), SupervisorError> {
        let body = br#"{"timeout_s": 10}"#.to_vec();
        self.call("POST", &format!("/v1/connectors/{id}/stop"), Some(body))
            .await
            .map(drop)
    }

    pub async fn remove(&self, id: &str, keep_volume: bool) -> Result<(), SupervisorError> {
        let body = serde_json::json!({ "keep_volume": keep_volume })
            .to_string()
            .into_bytes();
        self.call("POST", &format!("/v1/connectors/{id}/remove"), Some(body))
            .await
            .map(drop)
    }

    async fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<Vec<u8>>,
    ) -> Result<Value, SupervisorError> {
        tokio::time::timeout(TIMEOUT, self.call_once(method, path, body))
            .await
            .map_err(|_| {
                SupervisorError::Unavailable("the supervisor did not answer in time".into())
            })?
    }

    async fn call_once(
        &self,
        method: &str,
        path: &str,
        body: Option<Vec<u8>>,
    ) -> Result<Value, SupervisorError> {
        let down = |what: &str, err: &dyn std::fmt::Display| {
            SupervisorError::Unavailable(format!("{what}: {err}"))
        };
        let stream = UnixStream::connect(&self.socket)
            .await
            .map_err(|e| down("cannot reach the supervisor", &e))?;
        let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
            .await
            .map_err(|e| down("supervisor handshake failed", &e))?;
        tokio::spawn(conn);
        let request = hyper::Request::builder()
            .method(method)
            .uri(path)
            .header("host", "supervisor")
            .header("authorization", format!("Bearer {}", self.secret))
            .header("content-type", "application/json")
            .header(
                "x-slimm-deployment",
                self.deployment.get().map_or("", String::as_str),
            )
            .body(Full::new(Bytes::from(body.unwrap_or_default())))
            .map_err(|e| down("bad supervisor request", &e))?;
        let response = sender
            .send_request(request)
            .await
            .map_err(|e| down("the supervisor dropped the request", &e))?;
        let status = response.status();
        let bytes = Limited::new(response.into_body(), MAX_ANSWER)
            .collect()
            .await
            .map_err(|e| down("reading the supervisor's answer failed", &e))?
            .to_bytes();
        let answer: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        if status.is_success() {
            return Ok(answer);
        }
        Err(refusal(&answer))
    }
}

/// Maps a `supervisor/1` error body onto [`SupervisorError`].
pub fn refusal(answer: &Value) -> SupervisorError {
    let code = answer
        .get("error")
        .and_then(Value::as_str)
        .unwrap_or("bad_request")
        .to_owned();
    let detail = answer
        .get("detail")
        .and_then(Value::as_str)
        .unwrap_or("the supervisor refused")
        .to_owned();
    if code == "runtime_unavailable" {
        SupervisorError::Unavailable(detail)
    } else {
        SupervisorError::Refused { code, detail }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    macro_rules! fixture {
        ($name:literal) => {
            serde_json::from_str::<Value>(include_str!(concat!(
                "../../../../../docs/connectors/supervisor-fixtures/",
                $name
            )))
            .unwrap()
        };
    }

    #[test]
    fn a_supervisor_on_another_protocol_is_reported_not_trusted() {
        assert!(check_protocol(&fixture!("hello.response.json")).is_ok());
        for hello in [
            serde_json::json!({"protocol": "supervisor/2"}),
            serde_json::json!({}),
        ] {
            let err = check_protocol(&hello).unwrap_err();
            assert!(
                err.detail().contains("upgrade the supervisor"),
                "{}",
                err.detail()
            );
        }
    }

    #[test]
    fn the_supervisor_fixtures_parse_on_the_server_side() {
        let list: Vec<Listed> =
            serde_json::from_value(fixture!("list.response.json")["connectors"].clone()).unwrap();
        assert_eq!(
            (
                list[0].state.as_str(),
                list[0].exit_code,
                list[0].oom_killed
            ),
            ("exited", Some(137), true)
        );
        assert_eq!(
            (list[0].volume_bytes, list[0].volume_over_limit),
            (Some(1_048_576), false)
        );
        let lines: Vec<LogLine> =
            serde_json::from_value(fixture!("logs.response.json")["lines"].clone()).unwrap();
        assert_eq!(lines[1].stream, "stderr");
        assert!(refusal(&fixture!("error.policy.json")).is_policy());
        assert!(matches!(
            refusal(&fixture!("error.runtime_unavailable.json")),
            SupervisorError::Unavailable(_)
        ));
        assert_eq!(fixture!("hello.response.json")["protocol"], "supervisor/1");
    }

    #[test]
    fn the_create_body_has_the_fixture_shape() {
        let egress = [EgressHost {
            host: "api.example.com".into(),
            port: 443,
        }];
        let body = CreateBody {
            image: "img",
            env: std::collections::BTreeMap::from([("SLIMM_TOKEN", "t".to_owned())]),
            limits: Limits {
                memory_mib: Some(128),
                cpus: Some(0.5),
                pids: Some(64),
                volume_mib: Some(256),
            },
            egress: &egress,
            egress_private: false,
            volume: true,
        };
        let ours = serde_json::to_value(&body).unwrap();
        let fixture = fixture!("create.request.json");
        let keys = |v: &Value| v.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
        assert_eq!(keys(&ours), keys(&fixture));
        assert_eq!(keys(&ours["limits"]), keys(&fixture["limits"]));
        assert_eq!(ours["egress"], fixture["egress"]);
    }
}
