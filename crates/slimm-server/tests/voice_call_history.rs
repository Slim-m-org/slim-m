// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice channel's call history (decision 0066), from signed LiveKit
//! webhook deliveries to `GET /channels/{id}/voice/calls`.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64STD;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, ChannelId, UserId};
use slimm_server::store::{PlaceRequest, Store, VoiceEventKind};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

struct World {
    app: Router,
    store: Store,
    owner: (String, String),
    kiki: (String, String),
    channel: String,
    _guard: support::TestDbGuard,
}

fn signed_webhook(body: &Value) -> Request<Body> {
    let bytes = serde_json::to_vec(body).unwrap();
    let header = BASE64URL.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
    let exp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 300;
    let claims =
        json!({ "iss": API_KEY, "exp": exp, "sha256": BASE64STD.encode(Sha256::digest(&bytes)) });
    let signing_input = format!(
        "{header}.{}",
        BASE64URL.encode(serde_json::to_vec(&claims).unwrap())
    );
    let mut mac = <Hmac<Sha256>>::new_from_slice(API_SECRET.as_bytes()).unwrap();
    mac.update(signing_input.as_bytes());
    let token = format!(
        "{signing_input}.{}",
        BASE64URL.encode(mac.finalize().into_bytes())
    );
    Request::builder()
        .method("POST")
        .uri("/voice/webhook")
        .header("authorization", token)
        .header("content-type", "application/webhook+json")
        .body(Body::from(bytes))
        .unwrap()
}

async fn session(store: &Store, name: &str) -> (String, String) {
    let account = store
        .create_account(name, name, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (token, account.id.to_string())
}

async fn world(prefix: &str) -> World {
    let (path, guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    // An address nothing listens on: the SFU never answers, so nobody counts as present.
    let voice = VoiceService::for_test("http://127.0.0.1:1", API_KEY, API_SECRET);
    let app = support::app::builder(store.clone()).voice(voice).router();
    let owner = session(&store, "owner").await;
    let kiki = session(&store, "kiki").await;
    let channel = store.create_channel("voice", "voice").await.unwrap();
    World {
        app,
        store,
        owner,
        kiki,
        channel: channel.id.to_string(),
        _guard: guard,
    }
}

impl World {
    async fn deliver(&self, event: &str, who: &str) {
        let body = json!({
            "event": event,
            "room": { "name": format!("channel-{}", self.channel) },
            "participant": { "identity": who },
        });
        let status = self
            .app
            .clone()
            .oneshot(signed_webhook(&body))
            .await
            .unwrap()
            .status();
        assert_eq!(status, StatusCode::NO_CONTENT);
    }

    async fn calls(&self, token: &str) -> (StatusCode, Value) {
        let uri = format!("/channels/{}/voice/calls", self.channel);
        let request = Request::builder()
            .uri(uri)
            .header("authorization", format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap();
        let response = self.app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    /// The webhook writes in a spawned task, so a read waits for it to land.
    async fn calls_once(&self, token: &str, events: usize) -> Value {
        for _ in 0..40 {
            let (status, body) = self.calls(token).await;
            assert_eq!(status, StatusCode::OK, "{body}");
            let seen: usize = body["calls"]
                .as_array()
                .unwrap()
                .iter()
                .map(|c| c["events"].as_array().unwrap().len())
                .sum();
            if seen >= events {
                return body;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        panic!("the webhook's events never reached the history");
    }
}

#[tokio::test]
async fn joins_and_leaves_become_a_call_with_its_timeline() {
    let w = world("slimm-call-history-basic").await;
    w.deliver("participant_joined", &w.owner.1).await;
    w.deliver("participant_joined", &w.kiki.1).await;
    w.deliver("participant_joined", &w.kiki.1).await;
    w.deliver("participant_left", &w.kiki.1).await;
    w.deliver("participant_left", &w.owner.1).await;

    let body = w.calls_once(&w.owner.0, 4).await;
    assert_eq!(body["retention_days"], 30);
    let calls = body["calls"].as_array().unwrap();
    assert_eq!(calls.len(), 1, "{body}");
    let call = &calls[0];
    assert!(call["ended_at"].as_i64().is_some());
    let kinds: Vec<&str> = call["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["kind"].as_str().unwrap())
        .collect();
    assert_eq!(
        kinds,
        ["joined", "joined", "left", "left"],
        "the duplicate join is gone"
    );
}

#[tokio::test]
async fn a_call_left_open_by_a_missed_leave_reads_as_over() {
    let w = world("slimm-call-history-open").await;
    w.deliver("participant_joined", &w.owner.1).await;
    let body = w.calls_once(&w.owner.0, 1).await;
    assert!(
        body["calls"][0]["ended_at"].as_i64().is_some(),
        "nobody LiveKit reports is in it, so it is over: {body}"
    );
}

#[tokio::test]
async fn a_hidden_member_is_left_out_for_everyone_but_themselves() {
    let w = world("slimm-call-history-hidden").await;
    let kiki = UserId(w.kiki.1.parse().unwrap());
    w.store
        .set_presence_visibility(kiki, slimm_server::presence::Visibility::Hidden)
        .await
        .unwrap();
    w.deliver("participant_joined", &w.owner.1).await;
    w.deliver("participant_joined", &w.kiki.1).await;
    let mine = w.calls_once(&w.kiki.0, 2).await;
    let theirs = w.calls_once(&w.owner.0, 1).await;
    let ids = |body: &Value| -> Vec<String> {
        body["calls"][0]["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["user_id"].as_str().unwrap().to_owned())
            .collect()
    };
    assert!(ids(&mine).contains(&w.kiki.1), "kiki sees herself");
    assert!(!ids(&theirs).contains(&w.kiki.1), "nobody else sees kiki");
}

#[tokio::test]
async fn reading_needs_the_channel_and_old_events_are_swept() {
    let w = world("slimm-call-history-access").await;
    let channel = ChannelId(w.channel.parse().unwrap());
    let owner = UserId(w.owner.1.parse().unwrap());
    let long_ago = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        - 40 * 24 * 60 * 60 * 1000;
    w.store
        .record_voice_event(channel, owner, VoiceEventKind::Joined, long_ago)
        .await
        .unwrap();
    let (status, body) = w.calls(&w.owner.0).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["calls"], json!([]), "past retention is never read");
    assert_eq!(w.store.sweep_voice_events().await.unwrap(), 1);

    let (outsider, outsider_id) = session(&w.store, "outsider").await;
    let deny = json!({"overwrites": [{
        "kind": "member", "id": outsider_id, "allow": 0,
        "deny": slimm_server::permissions::Permissions::VIEW_CHANNEL.bits(),
    }]});
    let request = Request::builder()
        .method("PUT")
        .uri(format!("/channels/{}/overwrites", w.channel))
        .header("authorization", format!("Bearer {}", w.owner.0))
        .header("content-type", "application/json")
        .body(Body::from(deny.to_string()))
        .unwrap();
    let status = w.app.clone().oneshot(request).await.unwrap().status();
    assert_eq!(status, StatusCode::OK);
    assert_eq!(w.calls(&outsider).await.0, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn what_landed_on_the_canvas_during_a_call_is_part_of_it() {
    let w = world("slimm-call-history-canvas").await;
    let channel = ChannelId(w.channel.parse().unwrap());
    let kiki = UserId(w.kiki.1.parse().unwrap());
    w.deliver("participant_joined", &w.kiki.1).await;
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    for _ in 0..3 {
        w.store
            .place_canvas_object(
                channel,
                kiki,
                CanvasObjectId::generate(),
                PlaceRequest {
                    kind: "stroke",
                    bounds: (0.0, 0.0, 1.0, 1.0),
                    props: "{}",
                    attachment: None,
                },
            )
            .await
            .expect("placed");
    }
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    w.deliver("participant_left", &w.kiki.1).await;

    let body = w.calls_once(&w.owner.0, 2).await;
    let canvas = &body["calls"][0]["canvas"];
    assert_eq!(canvas.as_array().unwrap().len(), 1, "{body}");
    assert_eq!(canvas[0]["kind"], "stroke");
    assert_eq!(canvas[0]["count"], 3);
    assert_eq!(canvas[0]["user_id"], json!(w.kiki.1));
    assert_eq!(body["canvas_object_count"], 3);
}
