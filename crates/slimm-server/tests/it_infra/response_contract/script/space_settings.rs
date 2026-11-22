// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `/space/*` settings, each put back to what the rest of the pass needs.

use serde_json::json;

use crate::response_contract::world::Contract;

pub(super) async fn space_settings_calls(c: &mut Contract, root: &str) {
    c.bare("getSpaceSettings", "GET", "/space/settings", root)
        .await;
    // Set back to what it already is, so the rest of the pass still runs
    // against an invite-only deployment.
    c.json(
        "updateSpaceSettings",
        "PATCH",
        "/space/settings",
        root,
        json!({"join_policy": "invite", "hide_bots_in_member_list": false, "welcome_message": "Welcome {user} to {space}", "debug_logging": "off"}),
    )
    .await;
    c.bare("getJoinGate", "GET", "/space/join-gate", root).await;
    // Left off, so nobody the rest of the pass registers waits behind it.
    let gate = json!({"enabled": false, "rules": "be kind", "rules_channel_id": null, "joins_paused": false});
    c.json("putJoinGate", "PUT", "/space/join-gate", root, gate)
        .await;
    c.bare("getSpaceRules", "GET", "/space/rules", root).await;
    c.bare("acceptSpaceRules", "POST", "/space/rules/accept", root)
        .await;

    // Off by default, exercising the `stats: null` branch before it is on.
    c.bare("getSpaceAnalytics", "GET", "/space/analytics", root)
        .await;

    c.bare("getSpaceRetention", "GET", "/space/retention", root)
        .await;
    c.bare(
        "previewSpaceRetention",
        "GET",
        "/space/retention/preview?days=30",
        root,
    )
    .await;
    // Set back to disabled, so the rest of the pass keeps its own history.
    c.json(
        "updateSpaceRetention",
        "PATCH",
        "/space/retention",
        root,
        json!({"retention_days": 30}),
    )
    .await;
    c.json(
        "updateSpaceRetention",
        "PATCH",
        "/space/retention",
        root,
        json!({"retention_days": 0}),
    )
    .await;

    c.bare("getSpaceCanvasCap", "GET", "/space/canvas-cap", root)
        .await;
    // Change it and set it back, so the rest of the pass keeps the default.
    c.json(
        "updateSpaceCanvasCap",
        "PATCH",
        "/space/canvas-cap",
        root,
        json!({"object_cap": 5000}),
    )
    .await;
    c.json(
        "updateSpaceCanvasCap",
        "PATCH",
        "/space/canvas-cap",
        root,
        json!({"object_cap": 20000}),
    )
    .await;

    c.bare("getSpaceScreenShareCap", "GET", "/space/screen-share", root)
        .await;
    // Change it and set it back, so the rest of the pass keeps the default.
    c.json(
        "updateSpaceScreenShareCap",
        "PATCH",
        "/space/screen-share",
        root,
        json!({"max_height": 720}),
    )
    .await;
    c.json(
        "updateSpaceScreenShareCap",
        "PATCH",
        "/space/screen-share",
        root,
        json!({"max_height": 2160}),
    )
    .await;

    c.bare("getSpaceUplinkTests", "GET", "/space/uplink-test", root)
        .await;

    c.bare("getSpaceLinkPreviews", "GET", "/space/link-previews", root)
        .await;
    c.json(
        "updateSpaceLinkPreviews",
        "PATCH",
        "/space/link-previews",
        root,
        json!({"enabled": false}),
    )
    .await;
    // Back on, because later calls unfurl and embed images.
    c.json(
        "updateSpaceLinkPreviews",
        "PATCH",
        "/space/link-previews",
        root,
        json!({"enabled": true}),
    )
    .await;

    c.bare("getSpaceSetup", "GET", "/space/setup", root).await;
    c.bare("completeSpaceSetup", "POST", "/space/setup/complete", root)
        .await;
}
