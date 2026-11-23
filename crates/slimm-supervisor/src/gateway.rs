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

use request::{GatewayConfig, Head, parse_head};

const MAX_HEAD: usize = 16 * 1024;
const HEAD_TIMEOUT: Duration = Duration::from_secs(10);
const DIAL_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 256;

pub async fn run(config: GatewayConfig) -> std::io::Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", config.port)).await?;
    serve(listener, Arc::new(config)).await
}

pub async fn serve(listener: TcpListener, config: Arc<GatewayConfig>) -> std::io::Result<()> {
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        let (stream, peer) = listener.accept().await?;
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
    let (head, extra) = match tokio::time::timeout(HEAD_TIMEOUT, read_head(&mut client)).await {
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
    if forward_start(&mut client, &mut upstream, &head, &extra)
        .await
        .is_ok()
    {
        let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
    }
}

async fn forward_start(
    client: &mut TcpStream,
    upstream: &mut TcpStream,
    head: &Head,
    extra: &[u8],
) -> std::io::Result<()> {
    if head.connect {
        client
            .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
            .await?;
    } else {
        upstream.write_all(&head.upstream_head).await?;
    }
    upstream.write_all(extra).await
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

/// Reads up to the blank line; returns the head and any bytes that came after it.
async fn read_head(client: &mut TcpStream) -> std::io::Result<(Vec<u8>, Vec<u8>)> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 2048];
    loop {
        let n = client.read(&mut chunk).await?;
        if n == 0 {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let extra = buf.split_off(end + 4);
            buf.truncate(end);
            return Ok((buf, extra));
        }
        if buf.len() > MAX_HEAD {
            return Err(std::io::ErrorKind::InvalidData.into());
        }
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
