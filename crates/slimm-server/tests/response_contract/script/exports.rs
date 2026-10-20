// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Data exports, in call order: start, watch until the archive is ready,
//! download it, then delete it. The space export is started last and left to
//! finish in the background.

use std::time::Duration;

use serde_json::json;

use crate::world::Contract;

use super::{PASSWORD, text};

pub(crate) async fn export_calls(c: &mut Contract, root: &str) {
    let started = c
        .json(
            "startMemberExport",
            "POST",
            "/exports/member",
            root,
            json!({ "password": PASSWORD }),
        )
        .await;
    let id = text(&started, "id");
    wait_until_ready(c, root, &id).await;
    c.get("listExports", "/exports", root).await;
    c.get("downloadExport", &format!("/exports/{id}/download"), root)
        .await;
    c.bare("deleteExport", "DELETE", &format!("/exports/{id}"), root)
        .await;
    c.json(
        "startSpaceExport",
        "POST",
        "/exports/space",
        root,
        json!({ "password": PASSWORD }),
    )
    .await;
}

async fn wait_until_ready(c: &mut Contract, root: &str, id: &str) {
    for _ in 0..400 {
        let export = c.get("getExport", &format!("/exports/{id}"), root).await;
        match export["status"].as_str() {
            Some("ready") => return,
            Some("failed") => panic!("the member export failed: {export}"),
            _ => tokio::time::sleep(Duration::from_millis(25)).await,
        }
    }
    panic!("the member export never finished");
}
