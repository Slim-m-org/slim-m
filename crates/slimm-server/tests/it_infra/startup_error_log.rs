// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A server that cannot start says why in its log files, not only on stderr,
//! which a recreated container loses (decision 0129).

use std::net::TcpListener;
use std::process::Command;

use crate::support;

#[test]
fn a_port_already_taken_is_in_the_log_files() {
    let (dir, _guard) = support::TestDirGuard::new("slimm-startup-error-log");
    std::fs::create_dir_all(&dir).unwrap();
    let held = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = held.local_addr().unwrap().port();
    let logs = dir.join("logs");

    let output = Command::new(env!("CARGO_BIN_EXE_slimm-server"))
        .env_clear()
        .env("SLIMM_BIND_ADDRESS", "127.0.0.1")
        .env("SLIMM_PORT", port.to_string())
        .env("SLIMM_DATABASE_PATH", dir.join("slimm.db"))
        .env("SLIMM_ATTACHMENTS_DIR", dir.join("media"))
        .env("SLIMM_LOG_DIR", &logs)
        .output()
        .expect("run the binary");

    assert!(!output.status.success(), "the bind should have failed");
    let written: String = std::fs::read_dir(&logs)
        .expect("the server made its log directory")
        .map(|entry| std::fs::read_to_string(entry.unwrap().path()).unwrap())
        .collect();
    assert!(
        written.contains(&format!("binding to 127.0.0.1:{port}")),
        "the reason never reached the files:\n{written}"
    );
}
