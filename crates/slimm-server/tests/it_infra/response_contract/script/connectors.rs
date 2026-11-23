// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connector's surface (decision 0090): the manifest with its ask, the install
//! that shows its token, a new token, and what the connector reads about itself.

use serde_json::json;

use super::text;
use crate::response_contract::world::Contract;

const ID: &str = "jellyfin";

pub(super) async fn connector_calls(c: &mut Contract, root: &str) {
    let manifest = c
        .get("getDockModule", &format!("/space/dock/modules/{ID}"), root)
        .await;
    let asked = manifest["connector"]["permissions"].clone();
    let installed = c
        .json(
            "installDockModule",
            "POST",
            &format!("/space/dock/modules/{ID}/install"),
            root,
            json!({ "version": text(&manifest, "version"), "approved_connector_permissions": asked }),
        )
        .await;
    assert!(installed["connector_token"].is_string(), "{installed}");
    c.bare(
        "enableDockModule",
        "POST",
        &format!("/space/dock/modules/{ID}/enable"),
        root,
    )
    .await;
    let fresh = c
        .bare(
            "reissueConnectorToken",
            "POST",
            &format!("/space/dock/modules/{ID}/connector-token"),
            root,
        )
        .await;
    c.get("getConnectorSelf", "/connectors/me", &text(&fresh, "token"))
        .await;
    host_run_calls(c, root).await;
}

/// A host-run connector (decision 0134): whether the host can run one, its install, status and logs.
async fn host_run_calls(c: &mut Contract, root: &str) {
    let id = super::super::fake_supervisor::HOST_RUN_ID;
    slimm_server::http::connector_host::tick(&c.state).await;
    let runtime = c
        .get("getConnectorRuntime", "/space/dock/connector-runtime", root)
        .await;
    assert_eq!(runtime["configured"], json!(true), "{runtime}");
    let manifest = c
        .get("getDockModule", &format!("/space/dock/modules/{id}"), root)
        .await;
    let installed = c
        .json(
            "installDockModule",
            "POST",
            &format!("/space/dock/modules/{id}/install"),
            root,
            json!({
                "version": text(&manifest, "version"),
                "approved_connector_permissions": manifest["connector"]["permissions"],
                "approved_host_run": {"egress": manifest["connector"]["host_run"]["egress"]},
            }),
        )
        .await;
    assert!(installed.get("connector_token").is_none(), "{installed}");
    c.get(
        "getConnectorHostRun",
        &format!("/space/dock/modules/{id}/host-run"),
        root,
    )
    .await;
    c.get(
        "getConnectorHostRunLogs",
        &format!("/space/dock/modules/{id}/host-run/logs?tail=10"),
        root,
    )
    .await;
}
