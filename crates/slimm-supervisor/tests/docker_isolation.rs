// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The "no route out" claims of decision 0134 against a real Docker daemon: the host on
//! any of its addresses, the internal bridge's own address, and DNS through the embedded
//! resolver. Ignored by default; run with `-- --include-ignored`.

mod support;

use std::net::{SocketAddr, TcpListener};
use std::time::Duration;

use serde_json::{Value, json};
use support::Client;
use support::docker::{Stage, docker};

async fn create(client: &Client, id: &str, body: &Value) {
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/create"), &body.to_string())
        .await;
    assert_eq!(status, 200, "create: {answer}");
}

async fn start(client: &Client, id: &str) {
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/start"), "{}")
        .await;
    assert_eq!(status, 200, "start: {answer}");
}

async fn report(client: &Client, id: &str) -> Vec<String> {
    for _ in 0..180 {
        let (_, answer) = client
            .get(&format!("/v1/connectors/{id}/logs?tail=400"))
            .await;
        let lines: Vec<String> = answer["lines"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|l| l["text"].as_str().map(str::to_owned))
            .collect();
        if lines.iter().any(|l| l == "probe=done") {
            return lines;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    panic!("the probe never finished");
}

/// Every address the host holds, except loopback and other interfaces' link-local ones.
fn host_addresses() -> Vec<String> {
    let out = std::process::Command::new("ip")
        .args(["-o", "addr", "show"])
        .output()
        .expect("ip runs");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.split_whitespace().nth(3))
        .filter_map(|cidr| cidr.split('/').next())
        .filter(|a| !a.starts_with("127.") && *a != "::1" && !a.starts_with("fe80:"))
        .map(str::to_owned)
        .collect()
}

/// The bridge device's addresses, IPv6 link-local included, once it is up.
fn bridge_addresses(network: &str) -> Vec<String> {
    let id = docker(&["network", "inspect", "--format", "{{.Id}}", network]);
    let device = format!("br-{}", &id[..12]);
    let mut found = Vec::new();
    for _ in 0..50 {
        let out = std::process::Command::new("ip")
            .args(["-o", "addr", "show", "dev", &device])
            .output()
            .expect("ip runs");
        found = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| !l.contains("tentative"))
            .filter_map(|l| l.split_whitespace().nth(3))
            .filter_map(|cidr| cidr.split('/').next())
            .map(|a| match a.starts_with("fe80:") {
                true => format!("{a}%eth0"),
                false => a.to_owned(),
            })
            .collect();
        if found.iter().any(|a| a.starts_with("fe80:")) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    found
}

fn target(address: &str, port: u16) -> String {
    format!("{address}:{port}")
}

/// What busybox `nslookup` says about a name from a plain container on `network`.
fn lookup_from(network: &str, name: &str, stage: &Stage) -> &'static str {
    let control = format!("slimm-test-dns-{}", stage.run);
    let out = docker(&[
        "run",
        "--name",
        &control,
        "--label",
        &format!("{}={}", support::docker::TEST_LABEL, stage.run),
        "--network",
        network,
        "busybox:1.37.0",
        "sh",
        "-c",
        &format!("nslookup {name} 2>&1 || true"),
    ]);
    docker(&["container", "rm", "-f", &control]);
    if out.contains("NXDOMAIN") {
        "nxdomain"
    } else if out.contains("Name:") {
        "resolved"
    } else {
        "unanswered"
    }
}

#[tokio::test]
#[ignore = "needs Docker; run with --include-ignored"]
async fn a_connector_reaches_no_host_address_and_sends_no_dns_out() {
    let mut stage = Stage::new();
    let (client, instance) = stage.supervisor(&[]).await;
    let listener = TcpListener::bind("[::]:0".parse::<SocketAddr>().unwrap())
        .or_else(|_| TcpListener::bind("0.0.0.0:0"))
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let unique = format!("slimm-dns-{}.example.com", stage.run);
    let direct: Vec<String> = host_addresses().iter().map(|a| target(a, port)).collect();
    let id = uuid::Uuid::now_v7().hyphenated().to_string();
    let env = json!({
        "SLIMM_PROBE_DIRECT": direct.join(" "),
        "SLIMM_PROBE_TARGETS_URL": format!("http://{}:8080/targets", stage.server_name),
        "SLIMM_PROBE_HTTP": format!("http://{}:8080/ok", stage.server_name),
        "SLIMM_PROBE_DNS": format!("example.com {unique}"),
        "SLIMM_PROBE_FORGE": format!("{}:8080", stage.server_name),
    });
    create(
        &client,
        &id,
        &json!({"image": stage.probe_image, "env": env}),
    )
    .await;
    let network = format!("slimm-n-{instance}-{id}");
    let inspected: Value =
        serde_json::from_str(&docker(&["network", "inspect", &network])).unwrap();
    let gateways: Vec<&str> = inspected[0]["IPAM"]["Config"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|c| c["Gateway"].as_str())
        .filter(|g| !g.is_empty())
        .collect();
    start(&client, &id).await;
    let mut late: Vec<String> = bridge_addresses(&network)
        .iter()
        .chain(
            gateways
                .iter()
                .map(|g| (*g).to_owned())
                .collect::<Vec<_>>()
                .iter(),
        )
        .map(|a| target(a, port))
        .collect();
    late.dedup();
    let script = format!("printf '%s\\n' {} > /www/targets", late.join(" "));
    docker(&["exec", &stage.server_name, "sh", "-c", &script]);
    let lines = report(&client, &id).await;
    assert_eq!(
        line(&lines, "http "),
        format!("http http://{}:8080/ok => server-ok", stage.server_name),
        "the gateway still works: {lines:?}"
    );
    assert!(
        matches!(
            line(&lines, "ipv6_disabled="),
            "ipv6_disabled=1" | "ipv6_disabled=none"
        ),
        "{lines:?}"
    );
    for t in direct.iter().chain(late.iter()) {
        assert_eq!(
            line(&lines, &format!("direct {t} =>")),
            format!("direct {t} => closed"),
            "the host must be unreachable from the connector network: {lines:?}"
        );
    }
    assert!(
        gateways.is_empty(),
        "the connector network must give the host no address on it: {gateways:?}"
    );
    for kind in ["plain", "tunnel"] {
        assert_eq!(
            line(&lines, &format!("forge {kind} =>")),
            format!("forge {kind} => seen=1 forged=0"),
            "the server must never see a forwarding header a connector wrote: {lines:?}"
        );
    }
    let control = (
        lookup_from(&stage.egress_network, "example.com", &stage),
        lookup_from(&stage.egress_network, &unique, &stage),
    );
    if control == ("unanswered", "unanswered") {
        eprintln!("SKIPPED the DNS leak check: this runner's resolver answers nothing");
    } else {
        for name in ["example.com", unique.as_str()] {
            assert_eq!(
                line(&lines, &format!("dns {name} =>")),
                format!("dns {name} => unanswered"),
                "the embedded resolver forwarded a lookup out (control {control:?}): {lines:?}"
            );
        }
    }
    drop(listener);
}

fn line<'a>(lines: &'a [String], prefix: &str) -> &'a str {
    lines
        .iter()
        .find(|l| l.starts_with(prefix))
        .map_or("", String::as_str)
}
