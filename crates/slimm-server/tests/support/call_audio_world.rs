// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deployment where a module may hear a voice channel: a real fake listener
//! over WebSocket, calls joined and left through signed LiveKit webhooks, and
//! a recorder module whose stored events show what it was sent.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::call_audio::CallAudio;
use slimm_server::config::{Config, ListenerSettings};
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::{
    DockProvenance, InstallModuleRequest, ModulePlatform, ModuleRuntimeLimits, Store,
};
use slimm_server::voice::{VoiceService, room_for_channel};
use tower::ServiceExt;

use super::fake_listener::{FakeListener, SECRET};
use super::livekit_webhook::webhook_request;
use super::wait::wait_for;
use super::wasm_fixtures::{event_recorder_wasm, sha256_hex};

pub const MODULE: &str = "hearer";
const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";
pub const PURPOSE: &str = "Writes down what is said in the call.";
pub const KEEPS: &str = "The transcript text, for 30 days.";

#[derive(Clone)]
pub struct Person {
    pub id: UserId,
    pub token: String,
}

pub struct Rig {
    pub state: AppState,
    pub router: Router,
    pub store: Store,
    pub listener: FakeListener,
    pub admin: Person,
    pub people: Vec<Person>,
    pub channel: ChannelId,
    pub bot: UserId,
    _db: super::TestDbGuard,
    _dir: super::TestDirGuard,
}

fn manifest(wasm_sha: &str) -> String {
    json!({
        "schema": 1, "id": MODULE, "name": "Hearer", "version": "0.1.0", "summary": "hears calls",
        "artifact": {"kind": "wasm", "path": "m.wasm", "sha256": wasm_sha},
        "runtime": {"backend": "wasm", "limits": {}},
        "capabilities": ["call.audio", "kv.store"],
        "addon_api": 4,
        "call_audio": {"purpose": PURPOSE, "keeps": KEEPS},
    })
    .to_string()
}

impl Rig {
    /// A deployment with `how_many` members besides the admin, a voice channel, and the module armed for it.
    pub async fn start(name: &str, how_many: usize) -> Self {
        Self::start_with(name, how_many, 2, true).await
    }

    pub async fn start_with(name: &str, how_many: usize, max_sessions: u32, armed: bool) -> Self {
        let (path, db_guard) = super::TestDbGuard::new(name);
        let (dir, dir_guard) = super::TestDirGuard::new("slimm-call-audio-data");
        let config = Config {
            port: 0,
            database_path: path,
            hash_concurrency: 2,
            ..Config::default()
        };
        let store = Store::new(db::connect(&config).await.unwrap()).with_modules_dir(dir);
        let owner = store.create_account("owner", "Owner", "x").await.unwrap();
        store.bootstrap_deployment(owner.id).await.unwrap();
        let admin = Person {
            id: owner.id,
            token: store
                .open_session(owner.id, "t")
                .await
                .unwrap()
                .access_token,
        };
        let mut people = Vec::new();
        for n in 0..how_many {
            let user = store
                .create_user(&format!("p{n}"), &format!("P{n}"))
                .await
                .unwrap();
            let token = store.open_session(user.id, "t").await.unwrap().access_token;
            people.push(Person { id: user.id, token });
        }
        let channel = store.create_channel("lounge", "voice").await.unwrap().id;

        let listener = FakeListener::start(max_sessions).await;
        let call_audio = CallAudio::new(Some(ListenerSettings {
            url: listener.url(),
            secret: SECRET.into(),
            livekit_url: Some("ws://lan-livekit:7880".into()),
        }));
        let state = super::app::builder(store.clone())
            .voice(VoiceService::for_test(
                "wss://livekit.example.com",
                API_KEY,
                API_SECRET,
            ))
            .call_audio(call_audio)
            .build();
        std::mem::forget(slimm_server::call_audio::runtime::spawn(state.clone()));
        std::mem::forget(slimm_server::http::spawn_module_events(state.clone()));
        let router = http::router(state.clone());

        let wasm = event_recorder_wasm();
        let sha = sha256_hex(&wasm);
        let approved = vec!["call.audio".to_owned(), "kv.store".to_owned()];
        let manifest = manifest(&sha);
        let platform = ModulePlatform {
            addon_api: 4,
            ..ModulePlatform::default()
        };
        store
            .install_module_from_dock(
                InstallModuleRequest {
                    id: MODULE,
                    name: "Hearer",
                    version: "0.1.0",
                    artifact_sha256: &sha,
                    approved_capabilities: &approved,
                    runtime_limits: &ModuleRuntimeLimits::default(),
                    permissions: &[],
                    extension_points: &[],
                },
                &wasm,
                &DockProvenance {
                    manifest_json: Some(&manifest),
                    host_capabilities: &approved,
                    source_repo: None,
                    network_hosts: &[],
                    local_network_approved: false,
                    schedules: &[],
                    platform: &platform,
                },
            )
            .await
            .unwrap();
        store.set_module_enabled(MODULE, true).await.unwrap();
        let bot = store.ensure_module_bot(MODULE, "Hearer").await.unwrap();

        let rig = Self {
            state,
            router,
            store,
            listener,
            admin,
            people,
            channel,
            bot,
            _db: db_guard,
            _dir: dir_guard,
        };
        let state = rig.state.clone();
        wait_for("the listener to say ready", || {
            let ready = state.call_audio.is_ready();
            async move { ready.then_some(()) }
        })
        .await;
        if armed {
            let status = rig.arm(&[channel]).await;
            assert_eq!(status, StatusCode::OK);
        }
        rig
    }

    pub async fn arm(&self, channels: &[ChannelId]) -> StatusCode {
        let ids: Vec<String> = channels.iter().map(ToString::to_string).collect();
        let (status, _) = self
            .call(
                &self.admin,
                "PUT",
                &format!("/space/dock/modules/{MODULE}/call-audio-channels"),
                Some(json!({ "channel_ids": ids })),
            )
            .await;
        status
    }

    pub async fn call(
        &self,
        who: &Person,
        method: &str,
        uri: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {}", who.token));
        let body = match body {
            Some(body) => {
                builder = builder.header("content-type", "application/json");
                Body::from(body.to_string())
            }
            None => Body::empty(),
        };
        let response = self
            .router
            .clone()
            .oneshot(builder.body(body).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    fn uri(&self) -> String {
        format!("/channels/{}/voice/call-audio", self.channel)
    }

    pub async fn status(&self, who: &Person) -> Value {
        self.call(who, "GET", &self.uri(), None).await.1
    }

    pub async fn ask(&self, who: &Person) -> (StatusCode, Value) {
        let body = json!({ "module_id": MODULE });
        self.call(who, "POST", &self.uri(), Some(body)).await
    }

    pub async fn answer(&self, who: &Person, allow: bool) -> (StatusCode, Value) {
        let uri = format!("{}/consent", self.uri());
        self.call(who, "PUT", &uri, Some(json!({ "allow": allow })))
            .await
    }

    pub async fn stop(&self, who: &Person) -> StatusCode {
        self.call(who, "DELETE", &self.uri(), None).await.0
    }

    async fn deliver(&self, event: &str, identity: &str) {
        self.deliver_in(self.channel, event, identity).await;
    }

    pub async fn deliver_in(&self, channel: ChannelId, event: &str, identity: &str) {
        let body = json!({
            "event": event,
            "room": { "name": room_for_channel(channel) },
            "participant": { "identity": identity },
        });
        let response = self
            .router
            .clone()
            .oneshot(webhook_request(body, API_KEY, API_SECRET))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    pub async fn join(&self, who: &Person) {
        self.deliver("participant_joined", &who.id.to_string())
            .await;
    }

    pub async fn leave(&self, who: &Person) {
        self.deliver("participant_left", &who.id.to_string()).await;
    }

    pub async fn join_raw(&self, identity: &str) {
        self.deliver("participant_joined", identity).await;
    }

    /// Waits until the channel has (or no longer has) a session in `status`.
    pub async fn wait_session(&self, want: Option<&str>) -> Value {
        let (rig_state, channel) = (self.state.clone(), self.channel);
        wait_for("the session to reach the wanted status", || {
            let view = rig_state.call_audio.view(channel);
            async move {
                let status = view.as_ref().map(|v| v.status);
                (status == want).then(|| serde_json::to_value(&view).unwrap())
            }
        })
        .await
    }

    /// The session id the listener was told about last.
    pub fn session_id(&self) -> String {
        self.listener.of_type("start").last().unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    /// Everything the module has been sent, oldest first.
    pub async fn recorded(&self, at_least: usize) -> Vec<Value> {
        let store = self.store.clone();
        wait_for("the module's events", || {
            let store = store.clone();
            async move {
                let keys = store.module_kv_keys(MODULE, 1000).await.unwrap();
                let mut events = Vec::new();
                for key in keys {
                    let raw = store.module_kv_get(MODULE, &key).await.unwrap().unwrap();
                    let wire: Value = serde_json::from_str(&raw).unwrap();
                    let input = wire["input"]
                        .as_str()
                        .unwrap_or_else(|| panic!("no input in {wire}"));
                    events.push(serde_json::from_str::<Value>(input).unwrap());
                }
                (events.len() >= at_least).then(|| {
                    events.sort_by_key(|e: &Value| {
                        let id = e["id"].as_str().unwrap();
                        id.rsplit(':').next().unwrap().parse::<u64>().unwrap_or(0)
                    });
                    events
                })
            }
        })
        .await
    }
}

/// Wall-clock milliseconds, as the server counts them.
pub fn now_ms() -> i64 {
    i64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap()
}
