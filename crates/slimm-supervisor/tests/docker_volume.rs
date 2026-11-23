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
