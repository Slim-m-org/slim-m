// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The HTTP accept loop, with the limits `axum::serve` leaves off.
//!
//! A peer that opens a socket and sends nothing, or trickles a request head,
//! is dropped after [`HEADER_READ_TIMEOUT`], which on HTTP/1 also bounds how
//! long a keep-alive connection may sit idle between requests. Request bodies,
//! response bodies and upgraded WebSockets are outside that timer, so a large
//! upload or a long-lived socket is never cut by it. Live connections are
//! capped at [`MAX_CONNECTIONS`]; past it the loop stops accepting and the
//! kernel backlog holds new peers until a slot frees.

use std::convert::Infallible;
use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::ConnectInfo;
use axum::extract::Request;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper_util::rt::{TokioIo, TokioTimer};
use hyper_util::service::TowerToHyperService;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, watch};
use tower::ServiceExt;

/// How long a peer has to deliver a request head, or its first byte.
pub const HEADER_READ_TIMEOUT: Duration = Duration::from_secs(30);

/// The most connections served at once.
pub const MAX_CONNECTIONS: usize = 8192;

/// Serves `app` on `listener` until `shutdown` resolves, then lets open requests finish.
pub async fn serve(
    listener: TcpListener,
    app: Router,
    shutdown: impl Future<Output = ()>,
) -> std::io::Result<()> {
    serve_with_limits(
        listener,
        app,
        shutdown,
        HEADER_READ_TIMEOUT,
        MAX_CONNECTIONS,
    )
    .await
}

pub(crate) async fn serve_with_limits(
    listener: TcpListener,
    app: Router,
    shutdown: impl Future<Output = ()>,
    header_timeout: Duration,
    max_connections: usize,
) -> std::io::Result<()> {
    let slots = Arc::new(Semaphore::new(max_connections));
    let (stopping, _) = watch::channel(false);
    tokio::pin!(shutdown);
    loop {
        let permit = tokio::select! {
            permit = slots.clone().acquire_owned() => permit.expect("the semaphore is never closed"),
            () = &mut shutdown => break,
        };
        let (stream, peer) = tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok(pair) => pair,
                Err(error) => {
                    tracing::warn!(%error, "accepting a connection failed");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
            },
            () = &mut shutdown => break,
        };
        let stopping = stopping.subscribe();
        let app = app.clone();
        tokio::spawn(async move {
            let _slot = permit;
            let served = serve_connection(stream, peer, app, header_timeout, stopping);
            if let Err(error) = served.await {
                tracing::debug!(%error, %peer, "connection ended with an error");
            }
        });
    }
    stopping.send_replace(true);
    // Every connection task holds one slot until it ends.
    drop(slots.acquire_many(max_connections as u32).await);
    Ok(())
}

async fn serve_connection(
    stream: TcpStream,
    peer: SocketAddr,
    app: Router,
    header_timeout: Duration,
    mut stopping: watch::Receiver<bool>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let service = app.map_request(move |mut request: Request<Incoming>| {
        request.extensions_mut().insert(ConnectInfo(peer));
        request
    });
    let service = TowerToHyperService::new(service.map_err(|never: Infallible| match never {}));
    let connection = http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(header_timeout)
        .serve_connection(TokioIo::new(stream), service)
        .with_upgrades();
    tokio::pin!(connection);
    loop {
        tokio::select! {
            result = connection.as_mut() => return result.map_err(Into::into),
            _ = stopping.changed() => connection.as_mut().graceful_shutdown(),
        }
    }
}

#[cfg(test)]
mod tests {
    use axum::routing::{get, post};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    async fn start(header_timeout: Duration, max: usize) -> SocketAddr {
        let app = Router::new()
            .route("/ok", get(|| async { "ok" }))
            .route("/ws", get(socket))
            .route(
                "/peer",
                get(|ConnectInfo(peer): ConnectInfo<SocketAddr>| async move { peer.to_string() }),
            )
            .route(
                "/echo",
                post(|body: String| async move { body.len().to_string() }),
            );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let never = std::future::pending::<()>();
            let _ = serve_with_limits(listener, app, never, header_timeout, max).await;
        });
        addr
    }

    async fn socket(upgrade: axum::extract::WebSocketUpgrade) -> axum::response::Response {
        upgrade.on_upgrade(|mut ws| async move {
            while let Some(Ok(message)) = ws.recv().await {
                if ws.send(message).await.is_err() {
                    break;
                }
            }
        })
    }

    async fn read_to_end(stream: &mut TcpStream) -> String {
        let mut out = Vec::new();
        let _ = stream.read_to_end(&mut out).await;
        String::from_utf8_lossy(&out).into_owned()
    }

    #[tokio::test]
    async fn a_client_that_never_finishes_its_headers_is_dropped() {
        let addr = start(Duration::from_millis(300), 8).await;
        let mut slow = TcpStream::connect(addr).await.unwrap();
        slow.write_all(b"GET /ok HTTP/1.1\r\nHost: x\r\n")
            .await
            .unwrap();
        let dropped = tokio::time::timeout(Duration::from_secs(5), read_to_end(&mut slow)).await;
        assert!(dropped.is_ok(), "the half-sent head was never cut off");
    }

    #[tokio::test]
    async fn a_body_slower_than_the_header_timeout_is_not_cut() {
        let addr = start(Duration::from_millis(300), 8).await;
        let mut upload = TcpStream::connect(addr).await.unwrap();
        upload
            .write_all(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\nConnection: close\r\n\r\nabc")
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(900)).await;
        upload.write_all(b"def").await.unwrap();
        let reply = read_to_end(&mut upload).await;
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
        assert!(reply.ends_with('6'), "{reply}");
    }

    #[tokio::test]
    async fn connections_past_the_cap_wait_for_a_free_slot() {
        let addr = start(Duration::from_secs(30), 1).await;
        let mut first = TcpStream::connect(addr).await.unwrap();
        first
            .write_all(b"GET /ok HTTP/1.1\r\nHost: x\r\n\r\n")
            .await
            .unwrap();
        let mut buf = [0u8; 64];
        assert!(first.read(&mut buf).await.unwrap() > 0);

        let mut second = TcpStream::connect(addr).await.unwrap();
        second
            .write_all(b"GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        let held = tokio::time::timeout(Duration::from_millis(400), second.read(&mut buf)).await;
        assert!(held.is_err(), "a second connection was served past the cap");

        drop(first);
        let reply = tokio::time::timeout(Duration::from_secs(5), read_to_end(&mut second)).await;
        assert!(reply.unwrap().starts_with("HTTP/1.1 200"));
    }

    #[tokio::test]
    async fn an_upgraded_socket_outlives_the_header_timeout_and_peers_are_visible() {
        let addr = start(Duration::from_millis(300), 8).await;
        let mut stream = TcpStream::connect(addr).await.unwrap();
        let head = "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
        stream.write_all(head.as_bytes()).await.unwrap();
        let mut buf = [0u8; 512];
        let n = stream.read(&mut buf).await.unwrap();
        let head = String::from_utf8_lossy(&buf[..n]).into_owned();
        assert!(head.starts_with("HTTP/1.1 101"), "{head}");
        tokio::time::sleep(Duration::from_millis(900)).await;
        // A masked text frame "hi".
        stream
            .write_all(&[0x81, 0x82, 0, 0, 0, 0, b'h', b'i'])
            .await
            .unwrap();
        let n = stream.read(&mut buf).await.unwrap();
        assert_eq!(&buf[..n], &[0x81, 0x02, b'h', b'i']);

        let mut peer = TcpStream::connect(addr).await.unwrap();
        peer.write_all(b"GET /peer HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        assert!(read_to_end(&mut peer).await.contains("127.0.0.1:"));
    }
}
