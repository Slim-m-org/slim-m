// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `hello` against a real Docker daemon: the probe network is made while the runtime is not
//! known to be ready and never again after, though the server asks every 5 seconds.

mod support;

use support::docker::{Stage, docker};

#[tokio::test]
#[ignore = "needs Docker; run with --include-ignored"]
async fn hello_probes_the_runtime_once_it_is_ready() {
    let mut stage = Stage::new();
    let (client, instance) = stage.supervisor(&[]).await;
    let since = docker(&["system", "info", "--format", "{{.SystemTime}}"]);
    for _ in 0..3 {
        let (status, hello) = client.get("/v1/hello").await;
        assert_eq!(
            (status, hello["ready"].clone()),
            (200, serde_json::json!(true)),
            "{hello}"
        );
    }
    let until = docker(&["system", "info", "--format", "{{.SystemTime}}"]);
    let created = docker(&[
        "events",
        "--since",
        &since,
        "--until",
        &until,
        "--filter",
        "type=network",
        "--filter",
        "event=create",
        "--filter",
        &format!("network=slimm-probe-{instance}"),
        "--format",
        "{{.Actor.Attributes.name}}",
    ]);
    assert_eq!(
        created.lines().count(),
        1,
        "one probe network for three hellos: {created}"
    );
}
