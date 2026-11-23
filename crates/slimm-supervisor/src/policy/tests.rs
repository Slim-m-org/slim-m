// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use serde_json::json;

use super::*;

const IMAGE: &str = "ghcr.io/slim-m-org/example-connector@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn registries() -> Vec<String> {
    vec!["ghcr.io/slim-m-org/".to_owned()]
}

fn parse(body: serde_json::Value) -> Result<Spec, ApiError> {
    let req: CreateRequest = parse_body(body.to_string().as_bytes())?;
    validate(req, &registries(), &Ceilings::default())
}

fn code(body: serde_json::Value) -> crate::error::Code {
    parse(body).unwrap_err().code
}

#[test]
fn a_minimal_body_gets_the_decision_defaults() {
    let spec = parse(json!({"image": IMAGE})).unwrap();
    assert_eq!((spec.memory_mib, spec.cpus, spec.pids), (128, 0.5, 64));
    assert!(spec.egress.is_empty() && !spec.egress_private && !spec.volume);
}

#[test]
fn every_container_field_a_server_could_smuggle_is_refused() {
    use crate::error::Code::BadRequest;
    for (field, value) in [
        ("privileged", json!(true)),
        ("Privileged", json!(true)),
        ("binds", json!(["/:/host"])),
        (
            "mounts",
            json!([{"Type": "bind", "Source": "/var/run/docker.sock"}]),
        ),
        ("devices", json!(["/dev/kmsg"])),
        ("network_mode", json!("host")),
        ("NetworkMode", json!("host")),
        ("ports", json!({"80/tcp": [{"HostPort": "80"}]})),
        ("cap_add", json!(["SYS_ADMIN"])),
        ("CapAdd", json!(["NET_ADMIN"])),
        ("security_opt", json!(["seccomp=unconfined"])),
        ("user", json!("0:0")),
        ("pid_mode", json!("host")),
        ("cmd", json!(["sh"])),
        ("entrypoint", json!(["sh"])),
        ("labels", json!({"org.slim-m.instance": "other"})),
        ("HostConfig", json!({})),
    ] {
        let mut body = json!({"image": IMAGE});
        body[field] = value;
        assert_eq!(code(body), BadRequest, "{field} must be refused");
    }
    for (section, extra) in [
        ("limits", json!({"memory_mib": 64, "swap": 1})),
        ("limits", json!({"cpuset": "0"})),
    ] {
        assert_eq!(code(json!({"image": IMAGE, section: extra})), BadRequest);
    }
    assert_eq!(
        code(json!({"image": IMAGE, "egress": [{"host": "a.com", "port": 443, "via": "x"}]})),
        BadRequest
    );
}

#[test]
fn a_tag_or_a_missing_digest_is_refused() {
    use crate::error::Code::Policy;
    let digest = &IMAGE[IMAGE.find('@').unwrap()..];
    for image in [
        "ghcr.io/slim-m-org/example-connector:latest",
        "ghcr.io/slim-m-org/example-connector",
        "ghcr.io/slim-m-org/example-connector:1.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "ghcr.io/slim-m-org/example-connector@sha256:0123",
        "ghcr.io/slim-m-org/example-connector@sha256:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef",
        "ghcr.io/slim-m-org/example-connector@sha512:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    ] {
        assert_eq!(code(json!({"image": image})), Policy, "{image}");
    }
    for image in [
        format!("ghcr.io/evil-org/example{digest}"),
        format!("docker.io/library/alpine{digest}"),
        format!("ghcr.io/slim-m-org-evil/x{digest}"),
        format!("evil.com/ghcr.io/slim-m-org/x{digest}"),
        format!("ghcr.io/slim-m-org/../evil/x{digest}"),
        format!("GHCR.io/slim-m-org/x{digest}"),
    ] {
        assert_eq!(code(json!({"image": image})), Policy, "{image}");
    }
}

#[test]
fn env_keys_outside_slimm_are_refused() {
    use crate::error::Code::Policy;
    for key in [
        "PATH",
        "LD_PRELOAD",
        "HTTPS_PROXY",
        "http_proxy",
        "SLIMM_",
        "slimm_token",
        "SLIMM_token",
        "SLIMM_A-B",
        &format!("SLIMM_{}", "A".repeat(49)),
    ] {
        assert_eq!(
            code(json!({"image": IMAGE, "env": {key: "x"}})),
            Policy,
            "{key}"
        );
    }
    assert!(parse(json!({"image": IMAGE, "env": {"SLIMM_TOKEN": "t", "SLIMM_API_URL": "http://server:8080"}})).is_ok());
    assert_eq!(
        code(json!({"image": IMAGE, "env": {"SLIMM_A": "x".repeat(4097)}})),
        Policy
    );
    assert_eq!(
        code(json!({"image": IMAGE, "env": {"SLIMM_A": "a\u{0}b"}})),
        Policy
    );
    let total: serde_json::Map<_, _> = (0..5)
        .map(|i| (format!("SLIMM_K{i}"), json!("x".repeat(4000))))
        .collect();
    assert_eq!(code(json!({"image": IMAGE, "env": total})), Policy);
}

#[test]
fn limits_above_a_ceiling_are_refused_not_clamped() {
    use crate::error::Code::{BadRequest, Limit};
    assert_eq!(
        code(json!({"image": IMAGE, "limits": {"memory_mib": 513}})),
        Limit
    );
    assert_eq!(
        code(json!({"image": IMAGE, "limits": {"cpus": 1.01}})),
        Limit
    );
    assert_eq!(
        code(json!({"image": IMAGE, "limits": {"pids": 257}})),
        Limit
    );
    assert_eq!(
        code(json!({"image": IMAGE, "limits": {"pids": 0}})),
        BadRequest
    );
    assert_eq!(
        code(json!({"image": IMAGE, "limits": {"memory_mib": 8}})),
        BadRequest
    );
    assert_eq!(
        code(json!({"image": IMAGE, "limits": {"cpus": -1}})),
        BadRequest
    );
    assert_eq!(
        code(json!({"image": IMAGE, "limits": {"memory_mib": -1}})),
        BadRequest
    );
    let spec =
        parse(json!({"image": IMAGE, "limits": {"memory_mib": 512, "cpus": 1.0, "pids": 256}}))
            .unwrap();
    assert_eq!((spec.memory_mib, spec.cpus, spec.pids), (512, 1.0, 256));
}

#[test]
fn egress_is_bounded_and_normalized() {
    use crate::error::Code::{BadRequest, Policy};
    let many: Vec<_> = (0..33)
        .map(|i| json!({"host": format!("h{i}.com"), "port": 443}))
        .collect();
    assert_eq!(code(json!({"image": IMAGE, "egress": many})), Policy);
    assert_eq!(
        code(json!({"image": IMAGE, "egress": [{"host": "*", "port": 443}]})),
        Policy
    );
    assert_eq!(
        code(json!({"image": IMAGE, "egress": [{"host": "a.com", "port": 0}]})),
        Policy
    );
    assert_eq!(
        code(json!({"image": IMAGE, "egress": [{"host": "a.com", "port": 70000}]})),
        BadRequest
    );
    let spec = parse(json!({"image": IMAGE, "egress": [{"host": "API.Example.com", "port": 443}, {"host": "api.example.com", "port": 443}]})).unwrap();
    assert_eq!(spec.egress, vec![HostPort::new("api.example.com", 443)]);
}

#[test]
fn the_fingerprint_tells_bodies_apart() {
    let a = parse(json!({"image": IMAGE, "env": {"SLIMM_TOKEN": "slimbot_secret_a"}})).unwrap();
    let b = parse(json!({"image": IMAGE, "env": {"SLIMM_TOKEN": "slimbot_secret_b"}})).unwrap();
    let a_again = parse(json!({"image": IMAGE, "env": {"SLIMM_TOKEN": "slimbot_secret_a"}, "limits": {"memory_mib": 128}})).unwrap();
    assert_ne!(a.fingerprint(), b.fingerprint());
    assert_eq!(a.fingerprint(), a_again.fingerprint());
    assert!(!format!("{a:?}").contains("slimbot_secret_a"));
}

#[test]
fn ids_must_be_canonical_uuids() {
    assert!(connector_id("0196f2a0-0000-7000-8000-000000000001").is_ok());
    for bad in [
        "../etc",
        "0196F2A0-0000-7000-8000-000000000001",
        "0196f2a000007000800000000000000001",
        "x",
        "",
    ] {
        assert!(connector_id(bad).is_err(), "{bad}");
    }
}

#[test]
fn the_other_verb_bodies_refuse_unknown_fields() {
    assert!(parse_body::<StopRequest>(br#"{"timeout_s": 5, "signal": "KILL"}"#).is_err());
    assert!(parse_body::<RemoveRequest>(br#"{"keep_volume": true, "force_host": true}"#).is_err());
    assert!(parse_body::<StartRequest>(br#"{"privileged": true}"#).is_err());
    assert!(parse_body::<StartRequest>(b"").is_ok());
    assert!(parse_body::<RemoveRequest>(b"{}").is_ok_and(|r| !r.keep_volume));
}
