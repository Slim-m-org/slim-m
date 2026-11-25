// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The data volume ceiling against a real Docker daemon: a connector that writes past it is
//! stopped and reported, and is refused a start until it is under again. Run with `-- --include-ignored`.

mod support;

use std::time::Duration;

use serde_json::{Value, json};
use support::docker::{Stage, docker};

#[tokio::test]
#[ignore = "needs Docker; run with --include-ignored"]
async fn a_connector_past_its_volume_ceiling_is_stopped_and_not_started_again() {
    let mut stage = Stage::new();
    let (client, instance) = stage.supervisor(&[]).await;
    let id = uuid::Uuid::now_v7().hyphenated().to_string();
    let body = json!({"image": stage.probe_image, "volume": true, "limits": {"volume_mib": 2},
        "env": {"SLIMM_PROBE_FILL_MIB": "4"}});
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/create"), &body.to_string())
        .await;
    assert_eq!(status, 200, "{answer}");
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/start"), "{}")
        .await;
    assert_eq!(status, 200, "{answer}");
    let mut filled = false;
    for _ in 0..120 {
        let (_, logs) = client
            .get(&format!("/v1/connectors/{id}/logs?tail=50"))
            .await;
        filled = logs["lines"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|l| l["text"] == json!("probe=done"));
        if filled {
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(filled, "the probe never filled its volume");
    stage.handles[0].check_volumes().await.unwrap();
    let container = format!("slimm-c-{instance}-{id}");
    assert_eq!(
        docker(&["inspect", "--format", "{{.State.Status}}", &container]),
        "exited",
        "the supervisor stopped the connector"
    );
    let (_, list) = client.get("/v1/connectors").await;
    let state: &Value = &list["connectors"][0];
    assert_eq!(state["volume_over_limit"], json!(true), "{list}");
    assert!(
        state["volume_bytes"].as_u64().unwrap() > 2 * 1024 * 1024,
        "{list}"
    );
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/start"), "{}")
        .await;
    assert_eq!(
        (status, answer["error"].clone()),
        (422, json!("limit")),
        "{answer}"
    );
    assert!(
        answer["detail"]
            .as_str()
            .unwrap()
            .contains("over its 2 MiB limit"),
        "{answer}"
    );
}

async fn wait_for_probe(client: &support::Client, id: &str) {
    for _ in 0..240 {
        let (_, logs) = client
            .get(&format!("/v1/connectors/{id}/logs?tail=50"))
            .await;
        let done = logs["lines"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|l| l["text"] == json!("probe=done"));
        if done {
            return;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    panic!("the probe never finished");
}

#[tokio::test]
#[ignore = "needs Docker; run with --include-ignored"]
async fn many_small_files_past_the_allocated_ceiling_are_stopped() {
    let mut stage = Stage::new();
    let (client, instance) = stage.supervisor(&[]).await;
    let id = uuid::Uuid::now_v7().hyphenated().to_string();
    let body = json!({"image": stage.probe_image, "volume": true, "limits": {"volume_mib": 2},
        "env": {"SLIMM_PROBE_SMALL_FILES": "3000"}});
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/create"), &body.to_string())
        .await;
    assert_eq!(status, 200, "{answer}");
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/start"), "{}")
        .await;
    assert_eq!(status, 200, "{answer}");
    wait_for_probe(&client, &id).await;
    stage.handles[0].check_volumes().await.unwrap();
    let container = format!("slimm-c-{instance}-{id}");
    assert_eq!(
        docker(&["inspect", "--format", "{{.State.Status}}", &container]),
        "exited",
        "3000 small files hold more than 2 MiB of disk although their sizes add up to a few KiB"
    );
}

#[tokio::test]
#[ignore = "needs Docker; run with --include-ignored"]
async fn start_recreates_a_connector_network_the_runtime_dropped() {
    let mut stage = Stage::new();
    let (client, instance) = stage.supervisor(&[]).await;
    let id = uuid::Uuid::now_v7().hyphenated().to_string();
    let body = json!({"image": stage.probe_image, "volume": true});
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/create"), &body.to_string())
        .await;
    assert_eq!(status, 200, "{answer}");
    let (status, _) = client
        .post(&format!("/v1/connectors/{id}/stop"), "{}")
        .await;
    assert_eq!(status, 200);
    docker(&["rm", "-f", &format!("slimm-g-{instance}-{id}")]);
    docker(&["network", "rm", &format!("slimm-n-{instance}-{id}")]);
    let (status, answer) = client
        .post(&format!("/v1/connectors/{id}/start"), "{}")
        .await;
    assert_eq!(status, 200, "start after the network was pruned: {answer}");
}
