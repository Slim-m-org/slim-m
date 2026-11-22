// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Debug log submission and moderation calls.

use serde_json::json;

use crate::response_contract::world::Contract;

pub(super) async fn debug_log_calls(c: &mut Contract, root: &str, bob_token: &str) {
    let sent = c
        .json(
            "submitDebugLog",
            "POST",
            "/debug-logs",
            bob_token,
            json!({"log": "12:00:00  ERROR  [sync]  failed", "note": "settings reset", "app_version": "0.1.0", "platform": "linux"}),
        )
        .await;
    let uri = format!("/debug-logs/{}", sent["id"]);
    c.get("listDebugLogs", "/debug-logs", root).await;
    c.get("getDebugLog", &uri, root).await;
    c.bare("deleteDebugLog", "DELETE", &uri, root).await;
}
