// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `slimm-supervisor gateway`: the per-connector HTTP forward proxy that is the connector's
//! only way out, to the server's API and the approved `host:port` pairs (decision 0134).

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, lookup_host};
use tokio::sync::Semaphore;

pub mod request;

use request::{GatewayConfig, Head, Kind, Origin, parse_head, parse_tunnelled_head};

const MAX_HEAD: usize = 16 * 1024;
const HEAD_TIMEOUT: Duration = Duration::from_secs(10);
const DIAL_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 256;

pub async fn run(config: GatewayConfig) -> std::io::Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", config.port)).await?;
    serve(listener, Arc::new(config)).await
}

/// Where the gateway takes connections from; a seam so tests can inject accept errors.
pub trait Accept {
    fn accept(&self) -> impl Future<Output = std::io::Result<(TcpStream, SocketAddr)>> + Send;
}

impl Accept for TcpListener {
    fn accept(&self) -> impl Future<Output = std::io::Result<(TcpStream, SocketAddr)>> + Send {
        TcpListener::accept(self)
    }
}

pub async fn serve(listener: impl Accept, config: Arc<GatewayConfig>) -> std::io::Result<()> {
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        let Ok((stream, peer)) = Accept::accept(&listener).await else {
            tokio::time::sleep(Duration::from_millis(50)).await;
            continue;
        };
        if !config.client_allowed(peer.ip()) {
            log(
                "refused",
                "client",
                &peer.ip().to_string(),
                "not on the connector network",
            );
            continue;
        }
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let config = config.clone();
        tokio::spawn(async move {
            handle(stream, &config).await;
            drop(permit);
        });
    }
}

async fn handle(mut client: TcpStream, config: &GatewayConfig) {
    let (head, extra) =
        match tokio::time::timeout(HEAD_TIMEOUT, read_head(&mut client, Vec::new())).await {
            Ok(Ok(read)) => read,
            _ => return,
        };
    let head = match parse_head(&head) {
        Ok(head) => head,
        Err(reason) => return refuse(&mut client, "400 Bad Request", reason).await,
    };
    let target = head.target.to_string();
    let Some(kind) = config.classify(&head.target) else {
        log("refused", &target, "", "not an approved host");
        return refuse(
            &mut client,
            "403 Forbidden",
            "this host is not approved for the connector",
        )
        .await;
    };
    let addresses: Vec<SocketAddr> =
        match lookup_host((head.target.host.as_str(), head.target.port)).await {
            Ok(found) => found.collect(),
            Err(_) => Vec::new(),
        };
    if addresses.is_empty() {
        return refuse(&mut client, "502 Bad Gateway", "the host does not resolve").await;
    }
    let ips: Vec<IpAddr> = addresses.iter().map(SocketAddr::ip).collect();
    if let Err(ip) = config.check_addresses(kind, &ips) {
        log("refused", &target, &ip.to_string(), "address not allowed");
        return refuse(
            &mut client,
            "403 Forbidden",
            "the host resolves to an address the connector may not reach",
        )
        .await;
    }
    let Some(mut upstream) = dial(&addresses).await else {
        return refuse(&mut client, "502 Bad Gateway", "the host did not answer").await;
    };
    log(
        "allowed",
        &target,
        &upstream
            .peer_addr()
            .map(|a| a.ip().to_string())
            .unwrap_or_default(),
        "",
    );
    let _ = relay(&mut client, &mut upstream, (head, kind), extra).await;
}

/// A tunnel to an approved host is raw bytes; everything to the server is HTTP the
/// gateway reads, so a connector cannot send the server a header the filter dropped.
async fn relay(
    client: &mut TcpStream,
    upstream: &mut TcpStream,
    (head, kind): (Head, Kind),
    extra: Vec<u8>,
) -> std::io::Result<()> {
    if head.connect {
        client
            .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
            .await?;
        if kind != Kind::Server {
            upstream.write_all(&extra).await?;
            return tokio::io::copy_bidirectional(client, upstream)
                .await
                .map(drop);
        }
        let (inner, rest) = tokio::time::timeout(HEAD_TIMEOUT, read_head(client, extra))
            .await
            .map_err(|_| std::io::ErrorKind::TimedOut)??;
        return match parse_tunnelled_head(&inner) {
            Ok(origin) => forward_http(client, upstream, origin, rest).await,
            Err(reason) => {
                refuse(client, "400 Bad Request", reason).await;
                Ok(())
            }
        };
    }
    forward_http(client, upstream, head.upstream, extra).await
}

/// Sends one cleaned request; an upgrade is spliced through only once the server answers 101.
async fn forward_http(
    client: &mut TcpStream,
    upstream: &mut TcpStream,
    origin: Origin,
    extra: Vec<u8>,
) -> std::io::Result<()> {
    upstream.write_all(&origin.head).await?;
    if !origin.upgrade {
        upstream.write_all(&extra).await?;
        return tokio::io::copy_bidirectional(client, upstream)
            .await
            .map(drop);
    }
    let (answer, rest) = tokio::time::timeout(HEAD_TIMEOUT, read_head(upstream, Vec::new()))
        .await
        .map_err(|_| std::io::ErrorKind::TimedOut)??;
    client.write_all(&answer).await?;
    client.write_all(b"\r\n\r\n").await?;
    client.write_all(&rest).await?;
    if answer.starts_with(b"HTTP/1.1 101") {
        upstream.write_all(&extra).await?;
        return tokio::io::copy_bidirectional(client, upstream)
            .await
            .map(drop);
    }
    upstream.shutdown().await?;
    tokio::io::copy(upstream, client).await.map(drop)
}

async fn dial(addresses: &[SocketAddr]) -> Option<TcpStream> {
    for address in addresses {
        if let Ok(Ok(stream)) =
            tokio::time::timeout(DIAL_TIMEOUT, TcpStream::connect(address)).await
        {
            return Some(stream);
        }
    }
    None
}

/// Reads up to the blank line after `already`; returns the head and any bytes after it.
async fn read_head(
    stream: &mut TcpStream,
    already: Vec<u8>,
) -> std::io::Result<(Vec<u8>, Vec<u8>)> {
    let mut buf = already;
    let mut chunk = [0u8; 2048];
    loop {
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let extra = buf.split_off(end + 4);
            buf.truncate(end);
            return Ok((buf, extra));
        }
        if buf.len() > MAX_HEAD {
            return Err(std::io::ErrorKind::InvalidData.into());
        }
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        buf.extend_from_slice(&chunk[..n]);
    }
}

async fn refuse(client: &mut TcpStream, status: &str, reason: &str) {
    let body = format!("{reason}\n");
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = client.write_all(reply.as_bytes()).await;
    let _ = client.shutdown().await;
}

fn log(outcome: &str, target: &str, address: &str, reason: &str) {
    let line = serde_json::json!({"gateway": outcome, "target": target, "address": address, "reason": reason});
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Flaky {
        inner: TcpListener,
        failures: AtomicUsize,
    }

    impl Accept for Flaky {
        async fn accept(&self) -> std::io::Result<(TcpStream, SocketAddr)> {
            if self.failures.fetch_add(1, Ordering::SeqCst) < 2 {
                return Err(std::io::Error::other("too many open files"));
            }
            self.inner.accept().await
        }
    }

    #[tokio::test]
    async fn an_accept_error_does_not_stop_the_gateway() {
        let inner = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = inner.local_addr().unwrap();
        let config = GatewayConfig {
            allow: vec![],
            server: crate::net::HostPort::new("127.0.0.1", 9),
            egress_private: false,
            deny: vec![],
            clients: vec![crate::net::Cidr::parse("127.0.0.0/8").unwrap()],
            port: 0,
        };
        let task = tokio::spawn(serve(
            Flaky {
                inner,
                failures: AtomicUsize::new(0),
            },
            Arc::new(config),
        ));
        let mut client = TcpStream::connect(addr).await.unwrap();
        client
            .write_all(b"GET http://x.com/ HTTP/1.1\r\n\r\n")
            .await
            .unwrap();
        let mut reply = String::new();
        client.read_to_string(&mut reply).await.unwrap();
        assert!(reply.contains("403"), "{reply}");
        assert!(!task.is_finished());
    }
}
