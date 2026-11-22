// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module tile on a canvas, through the real router with two viewers: it is
//! placed, pressed, moved and removed like any object, its frame reaches every
//! viewer, and a press runs the module as whoever pressed.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState, run_scene_refreshes};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store,
};
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{json_body, json_body_or_null};
use support::wasm_fixtures::{canned_raw_wasm, echo_request_wasm, sha256_hex};
use support::ws::{
    Client, assert_no_frame_of_type, connect, read_frame_of_type, serve, user_ticket,
};

const TILE: &str = "Board";

async fn install(store: &Store, wasm: Vec<u8>) {
    let sha256 = sha256_hex(&wasm);
    let points = [
        ModuleExtensionPointSpec {
            kind: "command",
            name: "board",
            description: None,
            permission: Some("play"),
            command: None,
            language: None,
        },
        ModuleExtensionPointSpec {
            kind: "canvas-tile",
            name: TILE,
            description: Some("a shared board"),
            permission: Some("play"),
            command: Some("board"),
            language: None,
        },
    ];
    store
        .install_module_with_artifact(
            InstallModuleRequest {
                id: "board",
                name: "Board",
                version: "0.1.0",
                artifact_sha256: &sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[ModulePermissionSpec {
                    key: "play",
                    name: "Play",
                    description: "play",
                }],
                extension_points: &points,
            },
            &wasm,
        )
        .await
        .unwrap();
    store.set_module_enabled("board", true).await.unwrap();
}

struct Person {
    token: String,
    ticket: String,
    id: UserId,
}

struct Rig {
    store: Store,
    state: AppState,
    router: Router,
    channel: ChannelId,
    alice: Person,
    bob: Person,
    carol: Person,
    _guard: support::TestDbGuard,
}

/// Alice and Bob play the module; Carol can draw on the canvas but holds no module permission.
async fn rig(name: &str, wasm: Vec<u8>) -> Rig {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("hangout", "voice").await.unwrap().id;
    let players = store
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    install(&store, wasm).await;
    store
        .grant_module_permission(players, "board", "play")
        .await
        .unwrap();
    let mut people = Vec::new();
    for name in ["alice", "bob", "carol"] {
        let (token, ticket, id) = user_ticket(&store, name).await;
        if name != "carol" {
            store.assign_role(id, players).await.unwrap();
        }
        people.push(Person { token, ticket, id });
    }
    let carol = people.pop().unwrap();
    let bob = people.pop().unwrap();
    let alice = people.pop().unwrap();
    let state = support::app::state(store.clone());
    Rig {
        router: http::router(state.clone()),
        store,
        state,
        channel,
        alice,
        bob,
        carol,
        _guard: guard,
    }
}

fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(body) => builder
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

impl Rig {
    async fn call(&self, request: Request<Body>) -> (StatusCode, Value) {
        let response = self.router.clone().oneshot(request).await.unwrap();
        let status = response.status();
        (status, json_body_or_null(response).await)
    }

    async fn place(&self, who: &Person, props: Value) -> (StatusCode, Value) {
        let body = json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "module",
            "x": 100.0, "y": 80.0, "w": 640.0, "h": 480.0,
            "props": props,
        });
        let uri = format!("/channels/{}/canvas/objects", self.channel);
        self.call(request("POST", &uri, &who.token, Some(body)))
            .await
    }

    async fn place_tile(&self, who: &Person) -> String {
        let (status, body) = self
            .place(who, json!({"module_id": "board", "tile": TILE}))
            .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }

    fn scene_uri(&self, object: &str) -> String {
        format!("/channels/{}/canvas/objects/{object}/scene", self.channel)
    }

    async fn press(&self, who: &Person, object: &str, input: &str) -> (StatusCode, Value) {
        let uri = self.scene_uri(object);
        self.call(request(
            "POST",
            &uri,
            &who.token,
            Some(json!({ "input": input })),
        ))
        .await
    }

    async fn read_scene(&self, who: &Person, object: &str) -> (StatusCode, Value) {
        let uri = self.scene_uri(object);
        self.call(request("GET", &uri, &who.token, None)).await
    }

    async fn op(&self, who: &Person, op: Value) -> StatusCode {
        let uri = format!("/channels/{}/canvas/ops", self.channel);
        self.call(request("POST", &uri, &who.token, Some(op)))
            .await
            .0
    }

    async fn sockets(&self) -> (Client, Client) {
        let addr = serve(self.state.clone()).await;
        (
            connect(addr, &self.alice.ticket).await,
            connect(addr, &self.bob.ticket).await,
        )
    }
}

/// The module-scoped caller id the echo module was run with.
fn caller_of(echoed: &str) -> String {
    let start = echoed.find("'caller':{'id':'").expect("an echoed request") + 16;
    echoed[start..start + 64].to_owned()
}

async fn both_see(sockets: &mut (Client, Client), kind: &str) -> (Value, Value) {
    (
        read_frame_of_type(&mut sockets.0, kind).await,
        read_frame_of_type(&mut sockets.1, kind).await,
    )
}

#[tokio::test]
async fn two_viewers_place_press_move_and_remove_a_module_tile() {
    let r = rig("slimm-canvas-module-tile", echo_request_wasm()).await;
    let mut sockets = r.sockets().await;

    let object = r.place_tile(&r.alice).await;
    let (a, b) = both_see(&mut sockets, "canvas.object.placed").await;
    for frame in [&a, &b] {
        assert_eq!(frame["object"]["kind"], "module");
        assert_eq!(frame["object"]["props"]["tile"], TILE);
    }

    let (status, launch) = r.press(&r.alice, &object, "").await;
    assert_eq!(status, StatusCode::OK, "{launch}");
    assert_eq!(launch["ok"], true);
    let (a, b) = both_see(&mut sockets, "canvas.tile.scene_changed").await;
    assert_eq!(a, b, "every viewer gets the same frame");
    assert_eq!(a["object_id"], object.as_str());
    assert_eq!(a["ran_by"], r.alice.id.to_string());

    let (status, pressed) = r
        .press(
            &r.bob,
            &object,
            r#"{"action":"toggle:0,1","state":"forged"}"#,
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{pressed}");
    let output = pressed["output"].as_str().unwrap();
    let launched_by = caller_of(launch["output"].as_str().unwrap());
    assert_ne!(
        caller_of(output),
        launched_by,
        "the module ran as the second viewer, not the placer: {output}"
    );
    assert!(output.contains("toggle:0,1"), "{output}");
    assert!(
        !output.contains("forged"),
        "a client cannot hand the module a state: {output}"
    );
    let (a, b) = both_see(&mut sockets, "canvas.tile.scene_changed").await;
    for frame in [&a, &b] {
        assert_eq!(frame["output"], output, "Bob's press reached both viewers");
        assert_eq!(frame["ran_by"], r.bob.id.to_string());
    }
    let (status, stored) = r.read_scene(&r.alice, &object).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(stored["output"], output);

    let moved = json!({
        "id": Uuid::now_v7().to_string(), "kind": "move", "object_id": object,
        "x": 400.0, "y": 300.0, "w": 800.0, "h": 600.0,
    });
    assert_eq!(r.op(&r.alice, moved).await, StatusCode::CREATED);
    let (a, b) = both_see(&mut sockets, "canvas.object.moved").await;
    assert_eq!(a["w"], 800.0);
    assert_eq!(b["x"], 400.0);

    let removed =
        json!({"id": Uuid::now_v7().to_string(), "kind": "remove", "object_ids": [object]});
    assert_eq!(r.op(&r.alice, removed).await, StatusCode::CREATED);
    both_see(&mut sockets, "canvas.objects.removed").await;
    assert_eq!(r.press(&r.bob, &object, "").await.0, StatusCode::NOT_FOUND);
    assert_eq!(r.read_scene(&r.bob, &object).await.0, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn only_someone_who_may_use_the_module_places_its_declared_tile() {
    let r = rig("slimm-canvas-module-tile-gate", echo_request_wasm()).await;
    let tile = json!({"module_id": "board", "tile": TILE});
    assert_eq!(r.place(&r.carol, tile).await.0, StatusCode::FORBIDDEN);
    let unknown = json!({"module_id": "board", "tile": "Nope"});
    assert_eq!(r.place(&r.alice, unknown).await.0, StatusCode::CONFLICT);
    let missing = json!({"module_id": "gone", "tile": TILE});
    assert_eq!(r.place(&r.alice, missing).await.0, StatusCode::CONFLICT);
    let shapeless = json!({"module": "board"});
    assert_eq!(
        r.place(&r.alice, shapeless).await.0,
        StatusCode::BAD_REQUEST
    );

    let batch = json!({"objects": [{
        "id": Uuid::now_v7().to_string(), "kind": "module",
        "x": 0.0, "y": 0.0, "w": 10.0, "h": 10.0,
        "props": {"module_id": "board", "tile": TILE},
    }]});
    let uri = format!("/channels/{}/canvas/objects/batch", r.channel);
    let (status, _) = r
        .call(request("POST", &uri, &r.alice.token, Some(batch)))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let listed = |token: String| {
        let router = r.router.clone();
        async move {
            json_body(
                router
                    .oneshot(request("GET", "/modules/canvas-tiles", &token, None))
                    .await
                    .unwrap(),
            )
            .await
        }
    };
    let offered = listed(r.alice.token.clone()).await;
    assert_eq!(offered[0]["module_id"], "board");
    assert_eq!(offered[0]["tile"], TILE);
    assert_eq!(listed(r.carol.token.clone()).await, json!([]));
}

#[tokio::test]
async fn a_failed_press_answers_only_the_presser_and_keeps_the_frame() {
    let r = rig("slimm-canvas-module-tile-fail", echo_request_wasm()).await;
    let object = r.place_tile(&r.alice).await;
    assert_eq!(r.press(&r.alice, &object, "").await.0, StatusCode::OK);
    let (_, before) = r.read_scene(&r.alice, &object).await;

    install(&r.store, canned_raw_wasm(br#"{"ok":false,"error":"no"}"#)).await;
    let mut sockets = r.sockets().await;
    let (status, failed) = r.press(&r.bob, &object, r#"{"action":"x"}"#).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(failed["ok"], false);
    assert_no_frame_of_type(&mut sockets.0, "canvas.tile.scene_changed").await;
    let (_, after) = r.read_scene(&r.alice, &object).await;
    assert_eq!(after["output"], before["output"]);
}

#[tokio::test]
async fn a_tile_whose_module_is_off_says_why_and_can_still_be_removed() {
    let r = rig("slimm-canvas-module-tile-off", echo_request_wasm()).await;
    let object = r.place_tile(&r.alice).await;
    assert_eq!(r.press(&r.alice, &object, "").await.0, StatusCode::OK);

    r.store.set_module_enabled("board", false).await.unwrap();
    let (status, body) = r.read_scene(&r.bob, &object).await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(r.press(&r.bob, &object, "").await.0, StatusCode::CONFLICT);

    let removed =
        json!({"id": Uuid::now_v7().to_string(), "kind": "remove", "object_ids": [object]});
    assert_eq!(r.op(&r.alice, removed).await, StatusCode::CREATED);
}

const LIVE: &[u8] = br#"{"ok":true,"output":"{\"$slim\":\"scene/1\",\"ops\":[],\"state\":\"t1\",\"refresh_ms\":3000}"}"#;

#[tokio::test]
async fn a_tile_that_asks_is_redrawn_by_the_host_for_every_viewer() {
    let r = rig("slimm-canvas-module-tile-refresh", canned_raw_wasm(LIVE)).await;
    let object = r.place_tile(&r.alice).await;
    assert_eq!(r.press(&r.bob, &object, "").await.0, StatusCode::OK);
    let pending = r
        .store
        .due_canvas_tile_refreshes(i64::MAX, 10)
        .await
        .unwrap();
    assert_eq!(pending.len(), 1, "the press queued a redraw");

    let mut sockets = r.sockets().await;
    let now = i64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap();
    assert_eq!(
        run_scene_refreshes(&r.state, now).await.unwrap(),
        0,
        "not due yet"
    );
    assert_eq!(run_scene_refreshes(&r.state, now + 4_000).await.unwrap(), 1);
    let (a, b) = both_see(&mut sockets, "canvas.tile.scene_changed").await;
    assert_eq!(
        a["ran_by"],
        r.bob.id.to_string(),
        "a redraw runs as the last presser"
    );
    assert_eq!(a, b);
}
