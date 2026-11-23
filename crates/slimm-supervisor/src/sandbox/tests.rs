// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use std::collections::BTreeMap;

use serde_json::json;

use super::*;
use crate::net::HostPort;

const ID: &str = "0196f2a0-0000-7000-8000-000000000001";

fn spec(volume: bool) -> Spec {
    Spec {
        image: "ghcr.io/slim-m-org/x@sha256:00".into(),
        env: BTreeMap::from([("SLIMM_TOKEN".to_owned(), "t".to_owned())]),
        memory_mib: 128,
        cpus: 0.5,
        pids: 64,
        egress: vec![HostPort::new("api.example.com", 443)],
        egress_private: false,
        volume,
    }
}

/// The fixed hardening every container the supervisor makes must carry.
fn assert_hardened(body: &Value) {
    let host = &body["HostConfig"];
    assert_eq!(host["Privileged"], json!(false));
    assert_eq!(host["CapDrop"], json!(["ALL"]));
    assert_eq!(host["SecurityOpt"], json!(["no-new-privileges:true"]));
    assert_eq!(host["ReadonlyRootfs"], json!(true));
    assert_eq!(host["Binds"], json!([]));
    assert_eq!(host["Devices"], json!([]));
    assert_eq!(host["Sysctls"], json!({}));
    assert_eq!(host["PortBindings"], json!({}));
    assert_eq!(host["PublishAllPorts"], json!(false));
    assert_eq!(host["IpcMode"], json!("private"));
    assert_eq!(host["PidMode"], json!(""));
    assert_eq!(host["UTSMode"], json!(""));
    assert_eq!(host["Init"], json!(true));
    assert_eq!(host["RestartPolicy"], json!({"Name": "no"}));
    assert_eq!(
        host["LogConfig"]["Config"],
        json!({"max-size": "10m", "max-file": "3"})
    );
    assert!(
        host["Tmpfs"]["/tmp"]
            .as_str()
            .unwrap()
            .contains("noexec,nosuid")
    );
    assert!(host["Memory"].as_i64().unwrap() > 0 && host["MemorySwap"] == host["Memory"]);
    assert!(host["PidsLimit"].as_i64().unwrap() > 0 && host["NanoCpus"].as_i64().unwrap() > 0);
    let text = body.to_string();
    for forbidden in ["docker.sock", "runtime.sock", "unconfined", "\"host\""] {
        assert!(!text.contains(forbidden), "{forbidden} in {text}");
    }
    for mount in host["Mounts"].as_array().unwrap() {
        assert_eq!(mount["Type"], json!("volume"));
        assert_eq!(mount["Target"], json!("/data"));
    }
}

#[test]
fn the_connector_container_is_fixed_by_the_supervisor() {
    let names = Names::new("abcdef0123456789", ID);
    let body = connector_container(&names, &spec(true));
    assert_hardened(&body);
    assert_eq!(body["User"], json!("65532:65532"));
    assert_eq!(body.get("Cmd"), None);
    assert_eq!(body.get("Entrypoint"), None);
    assert_eq!(body["HostConfig"]["NetworkMode"], json!(names.network));
    assert_eq!(body["HostConfig"]["CapAdd"], json!([]));
    assert_eq!(body["HostConfig"]["Memory"], json!(128 * 1024 * 1024));
    assert_eq!(body["HostConfig"]["NanoCpus"], json!(500_000_000));
    assert_eq!(
        body["HostConfig"]["Mounts"][0]["Source"],
        json!(names.volume)
    );
    let env: Vec<&str> = body["Env"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert!(env.contains(&"HTTPS_PROXY=http://slimm-gateway:3128"));
    assert!(env.contains(&"SLIMM_TOKEN=t"));
    assert!(names.owns(&body["Labels"], "connector"));
    assert!(!names.owns(&body["Labels"], "gateway"));
    assert!(!Names::new("0000000000000000", ID).owns(&body["Labels"], "connector"));
}

#[test]
fn no_volume_means_no_mount() {
    let body = connector_container(&Names::new("abcdef0123456789", ID), &spec(false));
    assert_eq!(body["HostConfig"]["Mounts"], json!([]));
}

#[test]
fn the_gateway_and_chown_helper_carry_the_same_hardening() {
    let names = Names::new("abcdef0123456789", ID);
    let plan = GatewayPlan {
        egress: vec![HostPort::new("api.example.com", 443)],
        egress_private: false,
        server: HostPort::new("server", 8080),
        deny: vec![Cidr::parse("172.17.0.0/16").unwrap()],
        clients: vec![Cidr::parse("172.30.0.0/16").unwrap()],
    };
    let gateway = gateway_container(&names, "ghcr.io/slim-m-org/slim-m-supervisor:1", &plan);
    assert_hardened(&gateway);
    assert_eq!(gateway["User"], json!("65532:65532"));
    assert_eq!(gateway["Cmd"], json!(["gateway"]));
    assert_eq!(gateway["HostConfig"]["CapAdd"], json!([]));
    let env = gateway["Env"].to_string();
    assert!(env.contains("SLIMM_GATEWAY_ALLOW=api.example.com:443"));
    assert!(env.contains("SLIMM_GATEWAY_DENY=172.17.0.0/16"));
    let chown = chown_container(&names, "img");
    assert_hardened(&chown);
    assert_eq!(chown["HostConfig"]["CapAdd"], json!(["CHOWN"]));
    assert_eq!(chown["HostConfig"]["NetworkMode"], json!("none"));
}

#[test]
fn the_connector_network_is_internal() {
    let network = internal_network(&Names::new("abcdef0123456789", ID));
    assert_eq!(network["Internal"], json!(true));
    assert_eq!(network["Attachable"], json!(false));
}
