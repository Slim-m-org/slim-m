// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `supervisor/1` HTTP surface on the unix socket: the peer uid check, the bearer
//! secret, and one JSON log line per request.

use std::sync::Arc;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{ConnectInfo, Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::net::{UnixListener, UnixStream};

use crate::error::{ApiError, Code};
use crate::policy::{self, CreateRequest, RemoveRequest, StartRequest, StopRequest};
use crate::supervisor::Supervisor;

pub const MAX_BODY: usize = 64 * 1024;

/// The uid of the process on the other end of the socket.
#[derive(Debug, Clone, Copy)]
pub struct Peer {
    pub uid: u32,
}

impl axum::extract::connect_info::Connected<axum::serve::IncomingStream<'_, PeerListener>>
    for Peer
{
    fn connect_info(stream: axum::serve::IncomingStream<'_, PeerListener>) -> Self {
        *stream.remote_addr()
    }
}

/// A unix listener that drops every connection whose peer is not the server's uid.
pub struct PeerListener {
    pub inner: UnixListener,
    pub allowed_uid: u32,
}

impl axum::serve::Listener for PeerListener {
    type Io = UnixStream;
    type Addr = Peer;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            let Ok((stream, _)) = self.inner.accept().await else {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                continue;
            };
            match stream.peer_cred() {
                Ok(cred) if cred.uid() == self.allowed_uid => {
                    return (stream, Peer { uid: cred.uid() });
                }
                Ok(cred) => log_line("connect", "", cred.uid(), Err(Code::Unauthorized)),
                Err(_) => log_line("connect", "", u32::MAX, Err(Code::Unauthorized)),
            }
        }
    }

    fn local_addr(&self) -> std::io::Result<Self::Addr> {
        Ok(Peer {
            uid: self.allowed_uid,
        })
    }
}

type Shared = Arc<Supervisor>;

pub fn router(supervisor: Shared) -> Router {
    Router::new()
        .route("/v1/hello", get(hello))
        .route("/v1/connectors", get(list))
        .route("/v1/connectors/{id}/logs", get(logs))
        .route("/v1/connectors/{id}/create", post(create))
        .route("/v1/connectors/{id}/start", post(start))
        .route("/v1/connectors/{id}/stop", post(stop))
        .route("/v1/connectors/{id}/remove", post(remove))
        .fallback(|| async { ApiError::new(Code::NotFound, "no such route") })
        .with_state(supervisor)
}

/// Compares digests so neither the content nor the length of the secret leaks through timing.
pub fn secret_matches(given: &str, expected: &str) -> bool {
    let a = Sha256::digest(given.as_bytes());
    let b = Sha256::digest(expected.as_bytes());
    a.iter()
        .zip(b.iter())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

/// The header a server names its deployment with on every request (L5 of the 2026-11-23 review).
pub const DEPLOYMENT_HEADER: &str = "x-slimm-deployment";

fn authorize(supervisor: &Supervisor, headers: &HeaderMap) -> Result<(), ApiError> {
    let given = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    if !secret_matches(given, &supervisor.config.secret) {
        return Err(ApiError::new(
            Code::Unauthorized,
            "missing or wrong bearer secret",
        ));
    }
    let deployment = headers
        .get(DEPLOYMENT_HEADER)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    crate::checks::bind_deployment(&supervisor.config.state_dir, deployment)
}

fn log_line(verb: &str, id: &str, uid: u32, outcome: Result<(), Code>) {
    let (outcome, code) = match outcome {
        Ok(()) => ("ok", None),
        Err(code) => ("error", Some(code.as_str())),
    };
    println!(
        "{}",
        json!({"verb": verb, "connector": id, "peer_uid": uid, "outcome": outcome, "error": code})
    );
}

/// Authorizes, runs and logs one request; the body is parsed only after authorization.
async fn guarded<F, Fut>(
    verb: &str,
    id: &str,
    peer: Peer,
    headers: &HeaderMap,
    sup: &Supervisor,
    run: F,
) -> Response
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<serde_json::Value, ApiError>>,
{
    let result = match authorize(sup, headers) {
        Ok(()) => run().await,
        Err(err) => Err(err),
    };
    log_line(
        verb,
        id,
        peer.uid,
        result.as_ref().map(|_| ()).map_err(|e| e.code),
    );
    match result {
        Ok(body) => (StatusCode::OK, axum::Json(body)).into_response(),
        Err(err) => err.into_response(),
    }
}

async fn read_body(body: Body) -> Result<Bytes, ApiError> {
    axum::body::to_bytes(body, MAX_BODY)
        .await
        .map_err(|_| ApiError::bad_request("the request body is over 64 KiB"))
}

fn ok() -> serde_json::Value {
    json!({"v": 1})
}

async fn hello(
    State(sup): State<Shared>,
    ConnectInfo(peer): ConnectInfo<Peer>,
    headers: HeaderMap,
) -> Response {
    guarded("hello", "", peer, &headers, &sup, || sup.hello()).await
}

async fn list(
    State(sup): State<Shared>,
    ConnectInfo(peer): ConnectInfo<Peer>,
    headers: HeaderMap,
) -> Response {
    guarded("list", "", peer, &headers, &sup, || async {
        Ok(json!({"v": 1, "connectors": sup.list().await?}))
    })
    .await
}

#[derive(Deserialize)]
struct LogsQuery {
    tail: Option<usize>,
    since: Option<u64>,
}

async fn logs(
    State(sup): State<Shared>,
    ConnectInfo(peer): ConnectInfo<Peer>,
    headers: HeaderMap,
    Path(id): Path<String>,
    query: Result<Query<LogsQuery>, axum::extract::rejection::QueryRejection>,
) -> Response {
    guarded("logs", &id, peer, &headers, &sup, || async {
        let id = policy::connector_id(&id)?;
        let Query(q) =
            query.map_err(|_| ApiError::bad_request("tail and since must be numbers"))?;
        let lines = sup
            .logs(&id, q.tail.unwrap_or(200), q.since.unwrap_or(0))
            .await?;
        Ok(json!({"v": 1, "lines": lines}))
    })
    .await
}

async fn create(
    State(sup): State<Shared>,
    ConnectInfo(peer): ConnectInfo<Peer>,
    headers: HeaderMap,
    Path(id): Path<String>,
    body: Body,
) -> Response {
    guarded("create", &id, peer, &headers, &sup, || async {
        let id = policy::connector_id(&id)?;
        let body = read_body(body).await?;
        let req: CreateRequest = policy::parse_body(&body)?;
        sup.create(&id, req).await.map(|()| ok())
    })
    .await
}

async fn start(
    State(sup): State<Shared>,
    ConnectInfo(peer): ConnectInfo<Peer>,
    headers: HeaderMap,
    Path(id): Path<String>,
    body: Body,
) -> Response {
    guarded("start", &id, peer, &headers, &sup, || async {
        let id = policy::connector_id(&id)?;
        let body = read_body(body).await?;
        let _: StartRequest = policy::parse_body(&body)?;
        sup.start(&id).await.map(|()| ok())
    })
    .await
}

async fn stop(
    State(sup): State<Shared>,
    ConnectInfo(peer): ConnectInfo<Peer>,
    headers: HeaderMap,
    Path(id): Path<String>,
    body: Body,
) -> Response {
    guarded("stop", &id, peer, &headers, &sup, || async {
        let id = policy::connector_id(&id)?;
        let body = read_body(body).await?;
        let req: StopRequest = policy::parse_body(&body)?;
        let timeout = req.timeout_s.unwrap_or(10);
        if !(1..=30).contains(&timeout) {
            return Err(ApiError::bad_request("timeout_s must be 1 to 30"));
        }
        sup.stop(&id, timeout).await.map(|()| ok())
    })
    .await
}

async fn remove(
    State(sup): State<Shared>,
    ConnectInfo(peer): ConnectInfo<Peer>,
    headers: HeaderMap,
    Path(id): Path<String>,
    body: Body,
) -> Response {
    guarded("remove", &id, peer, &headers, &sup, || async {
        let id = policy::connector_id(&id)?;
        let body = read_body(body).await?;
        let req: RemoveRequest = policy::parse_body(&body)?;
        sup.remove(&id, req.keep_volume).await.map(|()| ok())
    })
    .await
}

/// Binds the socket mode 0660, replacing a stale one, and serves until the process ends.
pub async fn serve(supervisor: Shared) -> std::io::Result<()> {
    let path = supervisor.config.socket.clone();
    let _ = tokio::fs::remove_file(&path).await;
    let inner = UnixListener::bind(&path)?;
    use std::os::unix::fs::PermissionsExt;
    tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o660)).await?;
    let listener = PeerListener {
        inner,
        allowed_uid: supervisor.config.server_uid,
    };
    let app = router(supervisor).into_make_service_with_connect_info::<Peer>();
    axum::serve(listener, app).await
}
