// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `supervisor/1` surface over a real unix socket, with no container runtime behind it.

mod support;

use serde_json::{Value, json};
use support::{Client, TestDir, config, fixture, my_uid, start};

const ID: &str = "0196f2a0-0000-7000-8000-000000000001";

#[tokio::test]
async fn a_wrong_or_missing_secret_is_unauthorized() {
    let dir = TestDir::new("slimm-sup-api");
    let config = config(&dir.0, &[]);
    let mut client = Client::new(&config.socket);
    start(config, "aaaaaaaaaaaaaaaa").await;
    client.secret = "test-secret-0123456789abcdef012345678X".into();
    let (status, body) = client
        .post(&format!("/v1/connectors/{ID}/remove"), "{}")
        .await;
    assert_eq!(status, 401);
    assert_eq!(body["error"], json!("unauthorized"));
    assert_eq!(body["v"], json!(1));
    client.secret = String::new();
    assert_eq!(client.get("/v1/hello").await.0, 401);
}

#[tokio::test]
async fn a_peer_with_another_uid_is_dropped_before_any_request() {
    let dir = TestDir::new("slimm-sup-api");
    let uid = (my_uid() + 1).to_string();
    let config = config(&dir.0, &[("SLIMM_SUPERVISOR_SERVER_UID", &uid)]);
    let client = Client::new(&config.socket);
    start(config, "aaaaaaaaaaaaaaaa").await;
    assert!(client.send("GET", "/v1/hello", "").await.is_none());
}

#[tokio::test]
async fn the_socket_is_group_only() {
    use std::os::unix::fs::PermissionsExt;
    let dir = TestDir::new("slimm-sup-api");
    let config = config(&dir.0, &[]);
    let socket = config.socket.clone();
    start(config, "aaaaaaaaaaaaaaaa").await;
    assert_eq!(
        std::fs::metadata(socket).unwrap().permissions().mode() & 0o777,
        0o660
    );
}

#[tokio::test]
async fn smuggled_fields_are_refused_over_the_wire() {
    let dir = TestDir::new("slimm-sup-api");
    let config = config(&dir.0, &[]);
    let client = Client::new(&config.socket);
    start(config, "aaaaaaaaaaaaaaaa").await;
    let mut body: Value = serde_json::from_str(&fixture("create.request.json")).unwrap();
    body["privileged"] = json!(true);
    let (status, answer) = client
        .post(&format!("/v1/connectors/{ID}/create"), &body.to_string())
        .await;
    assert_eq!(
        (status, answer["error"].clone()),
        (400, json!("bad_request")),
        "{answer}"
    );
    let (status, answer) = client
        .post(
            &format!("/v1/connectors/{ID}/start"),
            r#"{"cap_add":["SYS_ADMIN"]}"#,
        )
        .await;
    assert_eq!(
        (status, answer["error"].clone()),
        (400, json!("bad_request"))
    );
    let (status, _) = client
        .post("/v1/connectors/..%2F..%2Fetc/start", "{}")
        .await;
    assert_eq!(status, 400);
    let (status, answer) = client
        .post(&format!("/v1/connectors/{ID}/stop"), r#"{"timeout_s": 31}"#)
        .await;
    assert_eq!(
        (status, answer["error"].clone()),
        (400, json!("bad_request"))
    );
}

#[tokio::test]
async fn a_body_over_64_kib_is_refused() {
    let dir = TestDir::new("slimm-sup-api");
    let config = config(&dir.0, &[]);
    let client = Client::new(&config.socket);
    start(config, "aaaaaaaaaaaaaaaa").await;
    let big = json!({"image": "x", "env": {"SLIMM_A": "a".repeat(70 * 1024)}}).to_string();
    let (status, answer) = client
        .post(&format!("/v1/connectors/{ID}/create"), &big)
        .await;
    assert_eq!(
        (status, answer["error"].clone()),
        (400, json!("bad_request"))
    );
}

#[tokio::test]
async fn a_policy_refusal_matches_its_fixture() {
    let dir = TestDir::new("slimm-sup-api");
    let config = config(&dir.0, &[]);
    let client = Client::new(&config.socket);
    start(config, "aaaaaaaaaaaaaaaa").await;
    let mut body: Value = serde_json::from_str(&fixture("create.request.json")).unwrap();
    body["image"] = json!("ghcr.io/slim-m-org/example-connector:latest");
    let (status, answer) = client
        .post(&format!("/v1/connectors/{ID}/create"), &body.to_string())
        .await;
    assert_eq!(status, 403);
    let expected: Value = serde_json::from_str(&fixture("error.policy.json")).unwrap();
    assert_eq!(answer, expected);
}

/// L1: without a deny list the docker host's own LAN address would be reachable.
#[tokio::test]
async fn the_private_network_is_refused_until_the_operator_names_the_host() {
    let dir = TestDir::new("slimm-sup-api");
    let config = config(&dir.0, &[]);
    let client = Client::new(&config.socket);
    start(config, "aaaaaaaaaaaaaaaa").await;
    let mut body: Value = serde_json::from_str(&fixture("create.request.json")).unwrap();
    body["egress_private"] = json!(true);
    let (status, answer) = client
        .post(&format!("/v1/connectors/{ID}/create"), &body.to_string())
        .await;
    assert_eq!(
        (status, answer["error"].clone()),
        (403, json!("policy")),
        "{answer}"
    );
    assert!(
        answer["detail"]
            .as_str()
            .unwrap()
            .contains("SLIMM_SUPERVISOR_LAN_DENY")
    );
}

/// L5: a second server on the same socket is refused, so its orphan sweep cannot remove the first one's connectors.
#[tokio::test]
async fn a_second_deployment_on_one_supervisor_is_refused() {
    let dir = TestDir::new("slimm-sup-api");
    let config = config(&dir.0, &[]);
    let first = Client::new(&config.socket);
    let mut second = Client::new(&config.socket);
    second.deployment = "another-deployment".into();
    start(config, "aaaaaaaaaaaaaaaa").await;
    assert_eq!(
        first
            .post(&format!("/v1/connectors/{ID}/remove"), "{}")
            .await
            .0,
        503,
        "bound; then the missing runtime answers"
    );
    let (status, answer) = second
        .post(&format!("/v1/connectors/{ID}/remove"), "{}")
        .await;
    assert_eq!(
        (status, answer["error"].clone()),
        (409, json!("conflict")),
        "{answer}"
    );
    assert_eq!(second.get("/v1/connectors").await.0, 409);
    second.deployment = String::new();
    assert_eq!(
        second.get("/v1/connectors").await.0,
        400,
        "a server must name itself"
    );
}

#[tokio::test]
async fn a_missing_runtime_is_runtime_unavailable() {
    let dir = TestDir::new("slimm-sup-api");
    let config = config(&dir.0, &[]);
    let client = Client::new(&config.socket);
    start(config, "aaaaaaaaaaaaaaaa").await;
    let expected: Value = serde_json::from_str(&fixture("error.runtime_unavailable.json")).unwrap();
    for (method, path, body) in [
        ("GET", "/v1/hello".to_owned(), ""),
        ("GET", "/v1/connectors".to_owned(), ""),
        (
            "POST",
            format!("/v1/connectors/{ID}/create"),
            fixture("create.request.json").leak() as &str,
        ),
        ("POST", format!("/v1/connectors/{ID}/remove"), "{}"),
    ] {
        let (status, answer) = client.send(method, &path, body).await.unwrap();
        assert_eq!(status, 503, "{path}: {answer}");
        assert_eq!(answer["error"], expected["error"]);
        assert!(
            answer["detail"]
                .as_str()
                .unwrap()
                .starts_with(expected["detail"].as_str().unwrap()),
            "{answer}"
        );
    }
}

#[test]
fn the_request_fixtures_parse_and_pass_the_default_policy() {
    use slimm_supervisor::config::Ceilings;
    use slimm_supervisor::policy::*;
    let create: CreateRequest = parse_body(fixture("create.request.json").as_bytes()).unwrap();
    validate(
        create,
        &["ghcr.io/slim-m-org/".to_owned()],
        &Ceilings::default(),
    )
    .unwrap();
    assert_eq!(
        parse_body::<StopRequest>(fixture("stop.request.json").as_bytes())
            .unwrap()
            .timeout_s,
        Some(10)
    );
    assert!(
        !parse_body::<RemoveRequest>(fixture("remove.request.json").as_bytes())
            .unwrap()
            .keep_volume
    );
    parse_body::<StartRequest>(fixture("start.request.json").as_bytes()).unwrap();
}

#[test]
fn the_response_fixtures_have_the_fields_the_supervisor_sends() {
    use slimm_supervisor::supervisor::state_of;
    let keys = |v: &Value| v.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    let list: Value = serde_json::from_str(&fixture("list.response.json")).unwrap();
    let ours = serde_json::to_value(state_of(ID, &json!({"State": {"Status": "exited"}}))).unwrap();
    assert_eq!(keys(&list["connectors"][0]), keys(&ours));
    let logs: Value = serde_json::from_str(&fixture("logs.response.json")).unwrap();
    let line = serde_json::to_value(slimm_supervisor::logs::Line {
        ts: String::new(),
        stream: "stdout",
        text: String::new(),
    })
    .unwrap();
    assert_eq!(keys(&logs["lines"][0]), keys(&line));
    let hello: Value = serde_json::from_str(&fixture("hello.response.json")).unwrap();
    let ceilings = serde_json::to_value(slimm_supervisor::config::Ceilings::default()).unwrap();
    assert_eq!(hello["ceilings"], ceilings);
}
