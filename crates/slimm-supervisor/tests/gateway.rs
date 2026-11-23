// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The egress gateway's refusals over a real TCP socket; what it lets through is proven
//! against real containers in `docker.rs`, since loopback is never an allowed upstream.

use std::sync::Arc;

use slimm_supervisor::gateway::{self, request::GatewayConfig};
use slimm_supervisor::net::{Cidr, HostPort};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

async fn gateway_with(allow: Vec<HostPort>, clients: &str) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let config = GatewayConfig {
        allow,
        server: HostPort::new("127.0.0.1", 9),
        egress_private: true,
        deny: vec![],
        clients: vec![Cidr::parse(clients).unwrap()],
        port: addr.port(),
    };
    tokio::spawn(gateway::serve(listener, Arc::new(config)));
    addr
}

async fn ask(gateway: std::net::SocketAddr, head: &str) -> String {
    let mut stream = TcpStream::connect(gateway).await.unwrap();
    stream.write_all(head.as_bytes()).await.unwrap();
    let mut answer = String::new();
    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        stream.read_to_string(&mut answer),
    )
    .await;
    answer
}

#[tokio::test]
async fn an_unapproved_host_is_forbidden() {
    let gw = gateway_with(vec![HostPort::new("api.example.com", 443)], "127.0.0.0/8").await;
    assert!(
        ask(gw, "CONNECT evil.example.com:443 HTTP/1.1\r\n\r\n")
            .await
            .starts_with("HTTP/1.1 403")
    );
    assert!(
        ask(gw, "CONNECT api.example.com:22 HTTP/1.1\r\n\r\n")
            .await
            .starts_with("HTTP/1.1 403")
    );
    assert!(
        ask(
            gw,
            "GET http://evil.example.com/ HTTP/1.1\r\nHost: evil.example.com\r\n\r\n"
        )
        .await
        .starts_with("HTTP/1.1 403")
    );
}

#[tokio::test]
async fn approved_loopback_and_metadata_are_still_forbidden() {
    let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = upstream.local_addr().unwrap().port();
    let allow = vec![
        HostPort::new("127.0.0.1", port),
        HostPort::new("169.254.169.254", 80),
        HostPort::new("localhost", port),
    ];
    let gw = gateway_with(allow, "127.0.0.0/8").await;
    for target in [
        format!("127.0.0.1:{port}"),
        "169.254.169.254:80".into(),
        format!("localhost:{port}"),
    ] {
        let answer = ask(gw, &format!("CONNECT {target} HTTP/1.1\r\n\r\n")).await;
        assert!(answer.starts_with("HTTP/1.1 403"), "{target}: {answer}");
    }
    assert!(
        ask(gw, "CONNECT 127.0.0.1:9 HTTP/1.1\r\n\r\n")
            .await
            .starts_with("HTTP/1.1 403"),
        "loopback server address"
    );
}

#[tokio::test]
async fn a_client_off_the_connector_network_gets_nothing() {
    let gw = gateway_with(vec![], "10.99.0.0/16").await;
    assert_eq!(
        ask(gw, "CONNECT api.example.com:443 HTTP/1.1\r\n\r\n").await,
        ""
    );
}

#[tokio::test]
async fn malformed_and_https_absolute_requests_are_bad_requests() {
    let gw = gateway_with(vec![], "127.0.0.0/8").await;
    assert!(
        ask(gw, "GET https://x.com/ HTTP/1.1\r\n\r\n")
            .await
            .starts_with("HTTP/1.1 400")
    );
    assert!(
        ask(gw, "GET /local HTTP/1.1\r\n\r\n")
            .await
            .starts_with("HTTP/1.1 400")
    );
}

/// A non-loopback address of this host, which the gateway may dial as the server; `None` offline.
fn local_address() -> Option<std::net::IpAddr> {
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    probe.connect("192.0.2.1:9").ok()?;
    let ip = probe.local_addr().ok()?.ip();
    (!ip.is_loopback() && !ip.is_unspecified()).then_some(ip)
}

/// A stand-in server: records each request head it reads and answers with `status`, then echoes.
async fn fake_server(
    ip: std::net::IpAddr,
    status: &'static str,
) -> (HostPort, Arc<std::sync::Mutex<Vec<String>>>) {
    let listener = TcpListener::bind((ip, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let record = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let record = record.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 4096];
                let n = stream.read(&mut buf).await.unwrap_or(0);
                record
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&buf[..n]).into_owned());
                let _ = stream.write_all(status.as_bytes()).await;
                while let Ok(n) = stream.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    record
                        .lock()
                        .unwrap()
                        .push(String::from_utf8_lossy(&buf[..n]).into_owned());
                    let _ = stream.write_all(&buf[..n]).await;
                }
            });
        }
    });
    (HostPort::new(&ip.to_string(), port), seen)
}

async fn gateway_for_server(server: HostPort) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let config = GatewayConfig {
        allow: vec![],
        server,
        egress_private: false,
        deny: vec![],
        clients: vec![Cidr::parse("127.0.0.0/8").unwrap()],
        port: addr.port(),
    };
    tokio::spawn(gateway::serve(listener, Arc::new(config)));
    addr
}

const UPGRADE: &str = "GET /ws HTTP/1.1\r\nHost: server\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nX-Forwarded-For: 6.6.6.6\r\n\r\n";

#[tokio::test]
async fn a_websocket_through_connect_reaches_the_server_without_forged_headers() {
    let Some(ip) = local_address() else {
        eprintln!("SKIPPED: this host has no non-loopback address");
        return;
    };
    let (server, seen) = fake_server(
        ip,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
    )
    .await;
    let gw = gateway_for_server(server.clone()).await;
    let mut stream = TcpStream::connect(gw).await.unwrap();
    let connect = format!("CONNECT {server} HTTP/1.1\r\nHost: {server}\r\n\r\n{UPGRADE}");
    stream.write_all(connect.as_bytes()).await.unwrap();
    let mut answer = vec![0u8; 512];
    let mut got = String::new();
    while !got.contains("101 Switching") {
        let n = stream.read(&mut answer).await.unwrap();
        assert!(n > 0, "the gateway closed before the upgrade: {got}");
        got.push_str(&String::from_utf8_lossy(&answer[..n]));
    }
    stream.write_all(b"frame-bytes").await.unwrap();
    let mut echoed = String::new();
    while !echoed.contains("frame-bytes") {
        let n = stream.read(&mut answer).await.unwrap();
        assert!(n > 0, "the upgraded stream closed");
        echoed.push_str(&String::from_utf8_lossy(&answer[..n]));
    }
    let seen = seen.lock().unwrap().join("");
    assert!(
        seen.contains("GET /ws HTTP/1.1") && !seen.contains("6.6.6.6"),
        "{seen}"
    );
}

#[tokio::test]
async fn a_refused_upgrade_lets_no_second_request_through() {
    let Some(ip) = local_address() else {
        eprintln!("SKIPPED: this host has no non-loopback address");
        return;
    };
    let (server, seen) =
        fake_server(ip, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n").await;
    let gw = gateway_for_server(server.clone()).await;
    let second = "GET /auth HTTP/1.1\r\nHost: server\r\nX-Forwarded-For: 7.7.7.7\r\n\r\n";
    let answer = ask(
        gw,
        &format!("CONNECT {server} HTTP/1.1\r\n\r\n{UPGRADE}{second}"),
    )
    .await;
    assert!(answer.contains("400 Bad Request"), "{answer}");
    let seen = seen.lock().unwrap().join("");
    assert!(
        !seen.contains("7.7.7.7") && !seen.contains("6.6.6.6"),
        "{seen}"
    );
}
