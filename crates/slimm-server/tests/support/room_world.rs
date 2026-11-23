// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice call with a module that keeps shared room state (decision 0131),
//! the people taking part, and the two room routes they use.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::{
    DockProvenance, InstallModuleRequest, ModulePlatform, ModuleRuntimeLimits, ModuleSlot,
};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

use super::livekit_webhook::webhook_request;
use super::module_world::{World, world_with};
use super::wasm_fixtures::{canned_raw_wasm, echo_request_in_wasm, sha256_hex};

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

/// The noughts proof module from slim-addons, exactly as its 0.2.0 manifest pins it.
pub fn noughts_wasm() -> Vec<u8> {
    let wasm = include_bytes!("../fixtures/noughts-0.2.0.wasm").to_vec();
    assert_eq!(
        sha256_hex(&wasm),
        "6c1a24786ea8591cc54fafd1fb226596c8fa8709b78f08057032635ac113c2d7",
        "tests/fixtures/noughts-0.2.0.wasm is not slim-addons' noughts 0.2.0"
    );
    wasm
}

/// A module whose room state is `{"r": "<the request it was run with>"}`, quotes read as `'`.
pub fn echo_room_wasm() -> Vec<u8> {
    echo_request_in_wasm(
        r#"{"ok":true,"output":"{\"$slim\":\"room/1\",\"state\":{\"r\":\""#,
        r#"\"}}"}"#,
    )
}

/// A module that answers `output` as its room reply every time.
pub fn canned_room_wasm(output: &Value) -> Vec<u8> {
    let wire = json!({ "ok": true, "output": output.to_string() });
    canned_raw_wasm(wire.to_string().as_bytes())
}

/// A module that answers `output` as its room reply, unless the input it is sent holds
/// `marker`, when it answers `ok:false`.
pub fn marker_fails_wasm(marker: &str, output: &Value) -> Vec<u8> {
    let ok = json!({ "ok": true, "output": output.to_string() }).to_string();
    let bad = r#"{"ok":false,"error":"the module tripped"}"#;
    let escape = |text: &str| text.replace('\\', "\\\\").replace('"', "\\\"");
    let (k, ok_len, bad_len) = (marker.len(), ok.len(), bad.len());
    let (marker, ok, bad) = (escape(marker), escape(&ok), escape(bad));
    let text = format!(
        r#"(module
            (memory (export "memory") 1)
            (data (i32.const 256) "{marker}")
            (data (i32.const 1024) "{bad}")
            (data (i32.const 2048) "{ok}")
            (func (export "alloc") (param $len i32) (result i32) (i32.const 32768))
            (func $at (param $p i32) (result i32) (local $k i32)
                (loop $l
                    (if (i32.ne (i32.load8_u (i32.add (local.get $p) (local.get $k)))
                                (i32.load8_u (i32.add (i32.const 256) (local.get $k))))
                        (then (return (i32.const 0))))
                    (local.set $k (i32.add (local.get $k) (i32.const 1)))
                    (br_if $l (i32.lt_u (local.get $k) (i32.const {k}))))
                (i32.const 1))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (local $i i32)
                (block $done
                    (loop $scan
                        (br_if $done (i32.gt_u (i32.add (local.get $i) (i32.const {k})) (local.get $in_len)))
                        (if (call $at (i32.add (local.get $in_ptr) (local.get $i)))
                            (then (return (i64.or (i64.shl (i64.const 1024) (i64.const 32)) (i64.const {bad_len})))))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $scan)))
                (i64.or (i64.shl (i64.const 2048) (i64.const 32)) (i64.const {ok_len}))))"#
    );
    wat::parse_str(&text).expect("marker-fails wasm fixture must parse")
}

pub struct RoomWorld {
    pub w: World,
    pub call: ChannelId,
    pub module: &'static str,
}

/// Someone with a session and a socket ticket.
pub struct Player {
    pub id: UserId,
    pub token: String,
    pub ticket: String,
}

/// A deployment with a voice channel and `module` installed with `room.state` approved,
/// declaring a call scene titled "Noughts and crosses" (decision 0133).
pub async fn room_world(name: &str, module: &'static str, wasm: Vec<u8>) -> RoomWorld {
    let voice = VoiceService::for_test("http://127.0.0.1:1", API_KEY, API_SECRET);
    let w = world_with(name, |builder| builder.voice(voice)).await;
    install_room_module(&w, module, &wasm).await;
    let call = w.store.create_channel("lounge", "voice").await.unwrap().id;
    RoomWorld { w, call, module }
}

async fn install_room_module(w: &World, id: &str, wasm: &[u8]) {
    let capabilities = ["room.state".to_owned()];
    let platform = ModulePlatform {
        addon_api: 6,
        slots: vec![ModuleSlot {
            kind: "call.scene".into(),
            name: "board".into(),
            title: Some("Noughts and crosses".into()),
        }],
        ..ModulePlatform::default()
    };
    w.store
        .install_module_from_dock(
            InstallModuleRequest {
                id,
                name: "Noughts",
                version: "0.2.0",
                artifact_sha256: &sha256_hex(wasm),
                approved_capabilities: &capabilities,
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[],
                extension_points: &[],
            },
            wasm,
            &DockProvenance {
                manifest_json: None,
                host_capabilities: &capabilities,
                source_repo: None,
                network_hosts: &[],
                local_network_approved: false,
                schedules: &[],
                platform: &platform,
            },
        )
        .await
        .unwrap();
    w.store.set_module_enabled(id, true).await.unwrap();
}

impl RoomWorld {
    pub async fn player(&self, name: &str) -> Player {
        let (token, ticket, id) = super::ws::user_ticket(&self.w.store, name).await;
        Player { id, token, ticket }
    }

    /// Puts `player` in the call, the way the client's heartbeat does.
    pub fn join_call(&self, player: &Player) {
        self.w
            .state
            .voice
            .record_heartbeat_reporting_new(player.id, self.call);
    }

    async fn call_json(&self, request: Request<Body>) -> (StatusCode, Value) {
        let response = self.w.router.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    /// Sends `input` to this world's module in `channel`, as `player`.
    pub async fn input_in(
        &self,
        player: &Player,
        channel: ChannelId,
        input: &str,
    ) -> (StatusCode, Value) {
        let request = Request::builder()
            .method("POST")
            .uri(format!(
                "/channels/{channel}/module-rooms/{}/inputs",
                self.module
            ))
            .header("authorization", format!("Bearer {}", player.token))
            .header("content-type", "application/json")
            .body(Body::from(json!({ "input": input }).to_string()))
            .unwrap();
        self.call_json(request).await
    }

    /// [`Self::input_in`] the call.
    pub async fn input(&self, player: &Player, input: &str) -> (StatusCode, Value) {
        self.input_in(player, self.call, input).await
    }

    /// The rooms in `channel`, as `player` reads them.
    pub async fn rooms_in(&self, player: &Player, channel: ChannelId) -> (StatusCode, Value) {
        let request = Request::builder()
            .uri(format!("/channels/{channel}/module-rooms"))
            .header("authorization", format!("Bearer {}", player.token))
            .body(Body::empty())
            .unwrap();
        self.call_json(request).await
    }

    /// The one room the call holds as `player` reads it, or `Null` when there is none.
    pub async fn room(&self, player: &Player) -> Value {
        let (status, body) = self.rooms_in(player, self.call).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["rooms"].get(0).cloned().unwrap_or(Value::Null)
    }

    /// LiveKit reports the call's room finished.
    pub async fn finish_call(&self) -> StatusCode {
        let body = json!({ "event": "room_finished", "room": { "name": format!("channel-{}", self.call) } });
        let request = webhook_request(body, API_KEY, API_SECRET);
        self.w
            .router
            .clone()
            .oneshot(request)
            .await
            .unwrap()
            .status()
    }
}
