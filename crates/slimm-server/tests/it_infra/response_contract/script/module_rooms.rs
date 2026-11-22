// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared room state (decision 0131): one input to a module that keeps room
//! state, then the room list holding the state and the scene it answered.

use serde_json::json;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
};

use crate::response_contract::world::Contract;
use crate::support::room_world::canned_room_wasm;
use crate::support::wasm_fixtures::sha256_hex;

const MODULE: &str = "room-keeper";

async fn install_room_module(c: &Contract) {
    let scene = json!({ "$slim": "scene/1", "width": 3, "height": 3, "ops": [] });
    let wasm =
        canned_room_wasm(&json!({ "$slim": "room/1", "state": { "turn": 1 }, "scene": scene }));
    let store = &c.state.store;
    let approved = ["room.state".to_owned()];
    let none_p: [ModulePermissionSpec; 0] = [];
    let none_e: [ModuleExtensionPointSpec; 0] = [];
    store
        .install_module_with_artifact(
            InstallModuleRequest {
                id: MODULE,
                name: "Room keeper",
                version: "0.1.0",
                artifact_sha256: &sha256_hex(&wasm),
                approved_capabilities: &approved,
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &none_p,
                extension_points: &none_e,
            },
            &wasm,
        )
        .await
        .unwrap();
    store
        .set_module_host_capabilities(MODULE, &approved)
        .await
        .unwrap();
    store.set_module_enabled(MODULE, true).await.unwrap();
}

pub(super) async fn module_room_calls(c: &mut Contract, root: &str, channel: &str) {
    install_room_module(c).await;
    c.json(
        "sendModuleRoomInput",
        "POST",
        &format!("/channels/{channel}/module-rooms/{MODULE}/inputs"),
        root,
        json!({ "input": "go" }),
    )
    .await;
    c.get(
        "listModuleRooms",
        &format!("/channels/{channel}/module-rooms"),
        root,
    )
    .await;
}
