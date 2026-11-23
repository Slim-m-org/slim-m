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
