// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use serde_json::json;

use super::*;

#[test]
fn runtime_states_map_onto_the_protocol() {
    let inspected = json!({"State": {"Status": "exited", "ExitCode": 137, "OOMKilled": true,
        "StartedAt": "2026-11-22T10:00:00Z", "FinishedAt": "2026-11-22T10:05:00Z"}, "Config": {"Image": "img"}});
    let state = state_of("id", &inspected);
    assert_eq!(
        (state.state, state.exit_code, state.oom_killed),
        ("exited", Some(137), true)
    );
    assert_eq!(state.image.as_deref(), Some("img"));
    let created = state_of(
        "id",
        &json!({"State": {"Status": "created", "StartedAt": "0001-01-01T00:00:00Z"}}),
    );
    assert_eq!((created.state, created.started_at), ("created", None));
    assert_eq!(
        state_of(
            "id",
            &json!({"State": {"Status": "running", "ExitCode": 0}})
        )
        .exit_code,
        None
    );
}

#[test]
fn the_gateway_is_rebuilt_from_the_connector_labels() {
    let inspected = json!({"Config": {"Labels": {EGRESS: "[{\"host\":\"a.com\",\"port\":443}]", EGRESS_PRIVATE: "1", VOLUME: "0"}}});
    assert_eq!(
        egress_of(&inspected),
        (vec![HostPort::new("a.com", 443)], true, false)
    );
    assert_eq!(egress_of(&json!({})), (vec![], false, false));
}
