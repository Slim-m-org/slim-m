// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `slimm-server --healthcheck`, the distroless image's liveness probe: it
//! passes only on a 200 from `/healthz` (issue 2097).

use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::Command;

/// Answers one connection with `status_line`, on a port of its own.
fn one_shot_server(status_line: &'static str) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut request = [0u8; 512];
            let _ = stream.read(&mut request);
            let _ = write!(stream, "{status_line}\r\nContent-Length: 2\r\n\r\nok");
        }
    });
    port
}

fn healthcheck(port: u16) -> bool {
    Command::new(env!("CARGO_BIN_EXE_slimm-server"))
        .arg("--healthcheck")
        .env("SLIMM_PORT", port.to_string())
        .env(
            "SLIMM_DATABASE_PATH",
            "/nonexistent/healthcheck-never-opens.db",
        )
        .output()
        .expect("run the binary")
        .status
        .success()
}

#[test]
fn a_200_passes() {
    assert!(healthcheck(one_shot_server("HTTP/1.1 200 OK")));
}

#[test]
fn a_503_fails() {
    assert!(!healthcheck(one_shot_server(
        "HTTP/1.1 503 Service Unavailable"
    )));
}

#[test]
fn nothing_listening_fails() {
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    assert!(!healthcheck(port));
}
