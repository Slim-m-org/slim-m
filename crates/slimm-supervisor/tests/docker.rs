// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The sandbox against a real Docker daemon. Ignored by default so a runner without Docker
//! skips them visibly; run with `cargo nextest run -p slimm-supervisor --run-ignored only`.

mod support;

use std::time::Duration;

use serde_json::{Value, json};
use support::Client;
use support::docker::{Stage, docker};

fn id() -> String {
    uuid::Uuid::now_v7().hyphenated().to_string()
}

fn create_body(stage: &Stage, env: Value, extra: Value) -> String {
    let mut body = json!({"image": stage.probe_image, "env": env, "volume": true});
    for (k, v) in extra.as_object().unwrap() {
        body[k] = v.clone();
    }
    body.to_string()
}

async fn create_and_start(client: &Client, id: &str, body: &str) {
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/create"), body)
        .await;
    assert_eq!(status, 200, "create: {answer}");
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/start"), "{}")
        .await;
    assert_eq!(status, 200, "start: {answer}");
}

/// The probe's report, once it has printed `probe=done`.
async fn report(client: &Client, id: &str) -> Vec<String> {
    for _ in 0..120 {
        let (status, answer) = client
            .get(&format!("/v1/connectors/{id}/logs?tail=200"))
            .await;
        assert_eq!(status, 200, "{answer}");
        let lines: Vec<String> = answer["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l["text"].as_str().unwrap().to_owned())
            .collect();
        if lines.iter().any(|l| l == "probe=done") {
            return lines;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    panic!("the probe never finished");
}

fn line<'a>(lines: &'a [String], prefix: &str) -> &'a str {
    lines
        .iter()
        .find(|l| l.starts_with(prefix))
        .map_or("", String::as_str)
}

fn egress_gateway_ip(stage: &Stage) -> String {
    docker(&[
        "network",
        "inspect",
        "--format",
        "{{(index .IPAM.Config 0).Gateway}}",
        &stage.egress_network,
    ])
}

#[tokio::test]
#[ignore = "needs Docker; run with --run-ignored only"]
async fn a_connector_runs_as_the_fixed_user_with_a_read_only_root_and_no_socket() {
    let mut stage = Stage::new();
    let (client, _) = stage.supervisor(&[]).await;
    let id = id();
    create_and_start(&client, &id, &create_body(&stage, json!({}), json!({}))).await;
    let lines = report(&client, &id).await;
    assert_eq!(line(&lines, "uid="), "uid=65532 gid=65532", "{lines:?}");
    assert_eq!(line(&lines, "rootfs="), "rootfs=readonly");
    assert_eq!(line(&lines, "tmp="), "tmp=writable");
    assert_eq!(line(&lines, "data="), "data=writable");
    assert_eq!(
        line(&lines, "socket="),
        "",
        "a runtime socket is visible: {lines:?}"
    );
    assert_eq!(line(&lines, "mount="), "");
    assert_eq!(line(&lines, "capeff="), "capeff=0000000000000000");
    assert_eq!(line(&lines, "nonewprivs="), "nonewprivs=1");
    assert_eq!(
        line(&lines, "seccomp="),
        "seccomp=2",
        "default seccomp filter"
    );
    if support::docker::daemon_has_lsm() {
        let lsm = line(&lines, "lsm=");
        assert!(
            lsm.len() > 4 && !lsm.contains("unconfined") && !lsm.contains("spc_t"),
            "the connector runs under the runtime's AppArmor or SELinux profile: {lsm}"
        );
    }
    let inspected: Value = serde_json::from_str(&docker(&[
        "inspect",
        &format!("slimm-c-{}-{id}", stage.instances[0]),
    ]))
    .unwrap();
    let host = &inspected[0]["HostConfig"];
    assert_eq!(host["Privileged"], json!(false));
    assert_eq!(host["Memory"], json!(128 * 1024 * 1024));
    assert_eq!(host["PidsLimit"], json!(64));
    assert_eq!(host["NanoCpus"], json!(500_000_000));
    assert_eq!(host["PortBindings"], json!({}));
    let (status, list) = client.get("/v1/connectors").await;
    assert_eq!(status, 200);
    assert_eq!(list["connectors"][0]["state"], json!("running"), "{list}");
}

#[tokio::test]
#[ignore = "needs Docker; run with --run-ignored only"]
async fn egress_reaches_only_the_server_and_approved_hosts() {
    let mut stage = Stage::new();
    let (client, _) = stage
        .supervisor(&[("SLIMM_SUPERVISOR_LAN_DENY", "10.99.0.0/16")])
        .await;
    let host_ip = egress_gateway_ip(&stage);
    let host_listener = std::net::TcpListener::bind("0.0.0.0:0").unwrap();
    let host_port = host_listener.local_addr().unwrap().port();
    let host_target = format!("{host_ip}:{host_port}");
    let internet = tokio::time::timeout(
        Duration::from_secs(5),
        tokio::net::TcpStream::connect("example.com:443"),
    )
    .await
    .is_ok_and(|r| r.is_ok());
    let connect = format!(
        "example.com:443 {host_target} 127.0.0.1:8080 169.254.169.254:80 10.99.0.5:80 10.1.2.3:80 evil.example.net:443"
    );
    let direct = format!(
        "{host_target} 169.254.169.254:80 1.1.1.1:443 {}:8080",
        stage.server_name
    );
    let http = format!("http://{}:8080/ok", stage.server_name);
    let env = json!({"SLIMM_PROBE_CONNECT": connect, "SLIMM_PROBE_DIRECT": direct, "SLIMM_PROBE_HTTP": http});
    let egress = json!([{"host": "example.com", "port": 443}, {"host": host_ip, "port": host_port},
        {"host": "127.0.0.1", "port": 8080}, {"host": "169.254.169.254", "port": 80}, {"host": "10.99.0.5", "port": 80}]);
    let id = id();
    create_and_start(
        &client,
        &id,
        &create_body(
            &stage,
            env,
            json!({"egress": egress, "egress_private": true}),
        ),
    )
    .await;
    let lines = report(&client, &id).await;
    let forbidden = |target: &str| {
        let got = line(&lines, &format!("connect {target} =>"));
        assert!(
            got.contains("403"),
            "{target} must be refused by the gateway: {lines:?}"
        );
    };
    forbidden(&host_target);
    forbidden("127.0.0.1:8080");
    forbidden("169.254.169.254:80");
    forbidden("10.99.0.5:80");
    forbidden("10.1.2.3:80");
    forbidden("evil.example.net:443");
    for target in [
        host_target.as_str(),
        "169.254.169.254:80",
        "1.1.1.1:443",
        &format!("{}:8080", stage.server_name),
    ] {
        assert_eq!(
            line(&lines, &format!("direct {target} =>")),
            format!("direct {target} => closed"),
            "{lines:?}"
        );
    }
    assert_eq!(
        line(&lines, "http "),
        format!("http {http} => server-ok"),
        "the server API through the gateway: {lines:?}"
    );
    if internet {
        let got = line(&lines, "connect example.com:443 =>");
        assert!(
            got.contains("200"),
            "an approved host through the gateway: {lines:?}"
        );
    } else {
        eprintln!("SKIPPED the approved public host check: this runner has no internet");
    }
    drop(host_listener);
}

#[tokio::test]
#[ignore = "needs Docker; run with --run-ignored only"]
async fn without_the_private_approval_a_lan_host_is_refused() {
    let mut stage = Stage::new();
    let (client, _) = stage.supervisor(&[]).await;
    let env = json!({"SLIMM_PROBE_CONNECT": "10.1.2.3:80 192.168.1.1:80"});
    let egress = json!([{"host": "10.1.2.3", "port": 80}, {"host": "192.168.1.1", "port": 80}]);
    let id = id();
    create_and_start(
        &client,
        &id,
        &create_body(&stage, env, json!({"egress": egress})),
    )
    .await;
    let lines = report(&client, &id).await;
    assert!(
        line(&lines, "connect 10.1.2.3:80 =>").contains("403"),
        "{lines:?}"
    );
    assert!(
        line(&lines, "connect 192.168.1.1:80 =>").contains("403"),
        "{lines:?}"
    );
}

#[tokio::test]
#[ignore = "needs Docker; run with --run-ignored only"]
async fn a_second_instance_never_sees_or_touches_the_first() {
    let mut stage = Stage::new();
    let (a, instance_a) = stage.supervisor(&[]).await;
    let (b, _) = stage.supervisor(&[]).await;
    let id = id();
    create_and_start(
        &a,
        &id,
        &create_body(&stage, json!({"SLIMM_PROBE_SLEEP": "600"}), json!({})),
    )
    .await;
    let (_, list) = b.get("/v1/connectors").await;
    assert_eq!(list["connectors"], json!([]), "{list}");
    assert_eq!(
        b.post(&format!("/v1/connectors/{id}/start"), "{}").await.0,
        404
    );
    assert_eq!(
        b.post(&format!("/v1/connectors/{id}/stop"), "{}").await.0,
        404
    );
    assert_eq!(b.get(&format!("/v1/connectors/{id}/logs")).await.0, 404);
    assert_eq!(
        b.post(&format!("/v1/connectors/{id}/remove"), "{}").await.0,
        200
    );
    let running = docker(&[
        "inspect",
        "--format",
        "{{.State.Status}}",
        &format!("slimm-c-{instance_a}-{id}"),
    ]);
    assert_eq!(running, "running");
    let (_, list) = a.get("/v1/connectors").await;
    assert_eq!(list["connectors"][0]["id"], json!(id));
}

#[tokio::test]
#[ignore = "needs Docker; run with --run-ignored only"]
async fn remove_keeps_the_volume_only_when_asked() {
    let mut stage = Stage::new();
    let (client, instance) = stage.supervisor(&[]).await;
    let volume_exists = |id: &str| {
        !docker(&[
            "volume",
            "ls",
            "-q",
            "--filter",
            &format!("name=slimm-v-{instance}-{id}"),
        ])
        .is_empty()
    };
    let (kept, gone) = (id(), id());
    for id in [&kept, &gone] {
        create_and_start(&client, id, &create_body(&stage, json!({}), json!({}))).await;
        report(&client, id).await;
    }
    assert_eq!(
        client
            .post(
                &format!("/v1/connectors/{kept}/remove"),
                r#"{"keep_volume": true}"#
            )
            .await
            .0,
        200
    );
    assert_eq!(
        client
            .post(
                &format!("/v1/connectors/{gone}/remove"),
                r#"{"keep_volume": false}"#
            )
            .await
            .0,
        200
    );
    assert!(volume_exists(&kept));
    assert!(!volume_exists(&gone));
    let leftovers = docker(&[
        "ps",
        "-aq",
        "--filter",
        &format!("label=org.slim-m.instance={instance}"),
    ]);
    assert_eq!(leftovers, "", "remove leaves no container");
    let networks = docker(&[
        "network",
        "ls",
        "-q",
        "--filter",
        &format!("label=org.slim-m.instance={instance}"),
    ]);
    assert_eq!(networks, "", "remove leaves no network");
    assert_eq!(
        client
            .post(&format!("/v1/connectors/{gone}/remove"), "{}")
            .await
            .0,
        200,
        "removing an unknown id succeeds"
    );
}

#[tokio::test]
#[ignore = "needs Docker; run with --run-ignored only"]
async fn create_is_idempotent_conflicts_on_a_new_body_and_respects_the_count() {
    let mut stage = Stage::new();
    let (client, _) = stage
        .supervisor(&[("SLIMM_SUPERVISOR_MAX_CONNECTORS", "1")])
        .await;
    let id = id();
    let body = create_body(&stage, json!({"SLIMM_TOKEN": "one"}), json!({}));
    assert_eq!(
        client
            .post(&format!("/v1/connectors/{id}/create"), &body)
            .await
            .0,
        200
    );
    assert_eq!(
        client
            .post(&format!("/v1/connectors/{id}/create"), &body)
            .await
            .0,
        200
    );
    let other = create_body(&stage, json!({"SLIMM_TOKEN": "two"}), json!({}));
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/create"), &other)
        .await;
    assert_eq!((status, answer["error"].clone()), (409, json!("conflict")));
    let (status, answer) = client
        .post(&format!("/v1/connectors/{}/create", self::id()), &body)
        .await;
    assert_eq!((status, answer["error"].clone()), (422, json!("limit")));
    let (_, list) = client.get("/v1/connectors").await;
    assert_eq!(list["connectors"][0]["state"], json!("created"));
    let (status, hello) = client.get("/v1/hello").await;
    assert_eq!(
        (status, hello["ready"].clone(), hello["connectors"].clone()),
        (200, json!(true), json!(1)),
        "{hello}"
    );
}

#[tokio::test]
#[ignore = "needs Docker; run with --run-ignored only"]
async fn a_crashed_connector_reports_its_exit_and_stop_is_idempotent() {
    let mut stage = Stage::new();
    let (client, _) = stage.supervisor(&[]).await;
    let id = id();
    create_and_start(
        &client,
        &id,
        &create_body(&stage, json!({"SLIMM_PROBE_SLEEP": "x"}), json!({})),
    )
    .await;
    let mut state = Value::Null;
    for _ in 0..60 {
        state = client.get("/v1/connectors").await.1["connectors"][0].clone();
        if state["state"] == json!("exited") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert_eq!(state["state"], json!("exited"), "{state}");
    assert_ne!(state["exit_code"], json!(0));
    assert_eq!(
        client
            .post(&format!("/v1/connectors/{id}/stop"), "{}")
            .await
            .0,
        200
    );
    assert_eq!(
        client
            .post(&format!("/v1/connectors/{id}/stop"), r#"{"timeout_s": 1}"#)
            .await
            .0,
        200
    );
    assert_eq!(
        client
            .post(&format!("/v1/connectors/{id}/start"), "{}")
            .await
            .0,
        200,
        "a crashed connector starts again"
    );
}
