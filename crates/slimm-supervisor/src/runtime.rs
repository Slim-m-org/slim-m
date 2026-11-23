// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A small Docker Engine API client over the runtime's unix socket (Podman serves the same API).

use std::path::PathBuf;
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Bytes;
use hyper::{Method, Request, StatusCode};
use hyper_util::rt::TokioIo;
use serde_json::Value;
use tokio::net::UnixStream;

use crate::error::ApiError;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);
const PULL_TIMEOUT: Duration = Duration::from_secs(600);
const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_PULL_BODY: usize = 64 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Runtime {
    socket: PathBuf,
}

/// A runtime answer: status and body.
#[derive(Debug)]
pub struct Reply {
    pub status: StatusCode,
    pub body: Bytes,
}

impl Reply {
    pub fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }

    pub fn ok(&self) -> bool {
        self.status.is_success() || self.status == StatusCode::NOT_MODIFIED
    }

    /// The runtime's own message, for a refusal the admin can read.
    pub fn message(&self) -> String {
        let json = self.json();
        json.get("message").and_then(Value::as_str).map_or_else(
            || String::from_utf8_lossy(&self.body).trim().to_owned(),
            str::to_owned,
        )
    }
}

impl Runtime {
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            socket: socket.into(),
        }
    }

    pub async fn get(&self, path: &str) -> Result<Reply, ApiError> {
        self.request(Method::GET, path, None, (DEFAULT_TIMEOUT, MAX_BODY))
            .await
    }

    /// [`Self::get`] giving up after `timeout`, for a report whose cost follows the host's size.
    pub async fn get_within(&self, path: &str, timeout: Duration) -> Result<Reply, ApiError> {
        self.request(Method::GET, path, None, (timeout, MAX_BODY))
            .await
    }

    pub async fn post(&self, path: &str, body: Option<&Value>) -> Result<Reply, ApiError> {
        self.request(Method::POST, path, body, (DEFAULT_TIMEOUT, MAX_BODY))
            .await
    }

    pub async fn delete(&self, path: &str) -> Result<Reply, ApiError> {
        self.request(Method::DELETE, path, None, (DEFAULT_TIMEOUT, MAX_BODY))
            .await
    }

    /// A pull streams progress lines; any line with an `error` fails the pull.
    pub async fn pull(&self, image: &str) -> Result<(), ApiError> {
        let path = format!("/images/create?fromImage={}", encode(image));
        let reply = self
            .request(Method::POST, &path, None, (PULL_TIMEOUT, MAX_PULL_BODY))
            .await?;
        if !reply.ok() {
            return Err(ApiError::policy(format!(
                "pulling {image} failed: {}",
                reply.message()
            )));
        }
        for line in reply.body.split(|b| *b == b'\n') {
            let event: Value = serde_json::from_slice(line).unwrap_or(Value::Null);
            if let Some(error) = event.get("error").and_then(Value::as_str) {
                return Err(ApiError::policy(format!("pulling {image} failed: {error}")));
            }
        }
        Ok(())
    }

    async fn request(
        &self,
        method: Method,
        path: &str,
        body: Option<&Value>,
        (timeout, cap): (Duration, usize),
    ) -> Result<Reply, ApiError> {
        tokio::time::timeout(timeout, self.request_once(method, path, body, cap))
            .await
            .map_err(|_| {
                ApiError::runtime(format!(
                    "the container runtime did not answer {path} in time"
                ))
            })?
    }

    async fn request_once(
        &self,
        method: Method,
        path: &str,
        body: Option<&Value>,
        cap: usize,
    ) -> Result<Reply, ApiError> {
        let stream = UnixStream::connect(&self.socket).await.map_err(|err| {
            ApiError::runtime(format!("cannot reach the container runtime: {err}"))
        })?;
        let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
            .await
            .map_err(|err| {
                ApiError::runtime(format!("container runtime handshake failed: {err}"))
            })?;
        tokio::spawn(conn);
        let bytes = body
            .map(|b| Bytes::from(serde_json::to_vec(b).unwrap_or_default()))
            .unwrap_or_default();
        let mut builder = Request::builder()
            .method(method)
            .uri(path)
            .header("host", "runtime");
        if body.is_some() {
            builder = builder.header("content-type", "application/json");
        }
        let request = builder
            .body(Full::new(bytes))
            .map_err(|err| ApiError::runtime(format!("bad runtime request: {err}")))?;
        let response = sender
            .send_request(request)
            .await
            .map_err(|err| ApiError::runtime(format!("container runtime request failed: {err}")))?;
        let status = response.status();
        let body = Limited::new(response.into_body(), cap)
            .collect()
            .await
            .map_err(|err| {
                ApiError::runtime(format!("reading the runtime's answer failed: {err}"))
            })?
            .to_bytes();
        Ok(Reply { status, body })
    }
}

/// Percent-encodes a query value.
pub fn encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// A label filter for the list endpoints, as the runtime's `filters` query takes it.
pub fn label_filter(labels: &[(&str, &str)]) -> String {
    let wanted: Vec<String> = labels.iter().map(|(k, v)| format!("{k}={v}")).collect();
    encode(&serde_json::json!({ "label": wanted }).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_values_are_encoded() {
        assert_eq!(
            encode("ghcr.io/a/b@sha256:ff"),
            "ghcr.io%2Fa%2Fb%40sha256%3Aff"
        );
        assert_eq!(label_filter(&[("a", "b")]), encode(r#"{"label":["a=b"]}"#));
    }
}
