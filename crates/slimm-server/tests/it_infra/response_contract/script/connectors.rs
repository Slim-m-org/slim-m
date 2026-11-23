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
}
