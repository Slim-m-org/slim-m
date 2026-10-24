// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The running server every case in `script.rs` talks to: one fixture, one
//! request helper, and the record of what has been covered so far.

use std::collections::BTreeSet;
use std::path::Path;

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::Request;
use axum::routing::get;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::gifs::GifSearch;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

use super::openapi::Api;
use super::verdict::{self, Answer};
use crate::support::wasm_fixtures;

pub enum Payload {
    None,
    Json(Value),
    Bytes(Vec<u8>),
}

pub struct Contract {
    pub(crate) state: AppState,
    api: Api,
    covered: BTreeSet<String>,
    problems: Vec<String>,
    /// The fake upstream's base URL, so the link-preview pass can point at its
    /// `/page`.
    pub upstream: String,
    /// Held, not read: its drop removes the temp database.
    _db: crate::support::TestDbGuard,
}

impl Contract {
    pub async fn new() -> Contract {
        let (database_path, db_guard) = crate::support::TestDbGuard::new("slimm-response-contract");
        let config = Config {
            port: 0,
            database_path,
            hash_concurrency: 2,
            ..Config::default()
        };
        let pool = db::connect(&config).await.expect("connect + migrate");
        let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let repo_root = manifest_dir
            .parent()
            .and_then(Path::parent)
            .expect("crates/slimm-server sits two directories below the repo root");

        let tenor_base = spawn_fake_tenor().await;
        let dock_base = spawn_fake_dock_registry().await;

        Contract {
            state: AppState {
                store: Store::new(pool),
                auth: Auth::new(2).expect("argon parameters"),
                hub: Hub::new(),
                limiter: RateLimiter::new(),
                push: PushSender::disabled(),
                // Configured rather than disabled so `mintVoiceToken` reaches
                // its documented 200, and its body gets checked, not a 501.
                voice: VoiceService::for_test("wss://sfu.invalid", "devkey", "devsecret"),
                media: Media::for_tests(),
                // Also configured, against a fake local provider, for the same reason.
                gifs: GifSearch::for_test("tenor", &tenor_base, "test-key"),
                link_previews: slimm_server::http::link_preview::LinkPreviews::for_test(),
                // Also configured, against a fake local registry, for the same reason.
                dock: slimm_server::http::dock::Dock::for_test(&dock_base),
                code_runner: slimm_server::code_runner::CodeRunner::disabled(),
            },
            api: Api::load(repo_root),
            covered: BTreeSet::new(),
            problems: Vec::new(),
            upstream: tenor_base,
            _db: db_guard,
        }
    }

    pub fn operation_ids(&self) -> BTreeSet<String> {
        self.api.operations.keys().cloned().collect()
    }

    pub fn covered(&self) -> &BTreeSet<String> {
        &self.covered
    }

    pub fn problems(&self) -> &[String] {
        &self.problems
    }

    pub async fn get(&mut self, op: &str, uri: &str, token: &str) -> Value {
        self.call(op, "GET", uri, Some(token), Payload::None).await
    }

    pub async fn bare(&mut self, op: &str, method: &str, uri: &str, token: &str) -> Value {
        self.call(op, method, uri, Some(token), Payload::None).await
    }

    pub async fn json(
        &mut self,
        op: &str,
        method: &str,
        uri: &str,
        token: &str,
        body: Value,
    ) -> Value {
        self.call(op, method, uri, Some(token), Payload::Json(body))
            .await
    }

    /// Issues one request and checks the response against the operation the
    /// schema documents under `op`.
    ///
    /// Every request gets a fresh router, and so a fresh rate-limit budget.
    /// A shared one would eventually answer 429 - a status the schema does
    /// document, which is exactly why it would be dangerous here: the
    /// operation would count as visited while its real body was never seen.
    pub async fn call(
        &mut self,
        op: &str,
        method: &str,
        uri: &str,
        token: Option<&str>,
        payload: Payload,
    ) -> Value {
        self.drive(op, method, uri, token, payload, false).await
    }

    /// Drives `op` expecting a refusal, and checks the refusal's body against
    /// the status the schema documents for it.
    ///
    /// Deliberately does NOT mark the operation covered. `covered` answers
    /// "was this operation's real response seen", and an error body is not
    /// that - counting it would let a happy path lapse while the enumeration
    /// still read as complete, which is the same trap this file's own note on
    /// the fresh rate limiter describes for 429.
    pub async fn refuses(
        &mut self,
        op: &str,
        method: &str,
        uri: &str,
        token: Option<&str>,
        payload: Payload,
    ) -> Value {
        self.drive(op, method, uri, token, payload, true).await
    }

    async fn drive(
        &mut self,
        op: &str,
        method: &str,
        uri: &str,
        token: Option<&str>,
        payload: Payload,
        expect_error: bool,
    ) -> Value {
        let mut builder = Request::builder().method(method).uri(uri);
        if let Some(token) = token {
            builder = builder.header("authorization", format!("Bearer {token}"));
        }
        let request = match payload {
            Payload::None => builder.body(Body::empty()),
            Payload::Json(value) => builder
                .header("content-type", "application/json")
                .body(Body::from(value.to_string())),
            Payload::Bytes(bytes) => builder
                .header("content-type", "application/octet-stream")
                .body(Body::from(bytes)),
        }
        .expect("a well-formed request");

        let router = http::router(AppState {
            limiter: RateLimiter::new(),
            ..self.state.clone()
        });
        let response = router.oneshot(request).await.expect("router answered");
        if !expect_error {
            self.covered.insert(op.to_string());
        }

        let status = response.status();
        let media_type = response
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok())
            .map(|value| value.split(';').next().unwrap_or(value).trim().to_owned());
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("a readable body");

        let (value, problems) = verdict::judge(
            &self.api,
            Answer {
                op,
                method,
                uri,
                status,
                media_type,
                bytes: &bytes,
                expect_error,
            },
        );
        self.problems.extend(problems);
        value
    }
}

/// A search-shaped like a real Tenor `/v2/search` response, embedding
/// `preview.gif`/`full.gif` URLs pointing back at itself, so `searchGifs`,
/// `getGifPreview` and `selectGif` each reach a genuine 2xx here rather than
/// the 501 a disabled `GifSearch` would answer with - the same reason
/// `mintVoiceToken` above is configured rather than disabled.
async fn spawn_fake_tenor() -> String {
    async fn search(State(base): State<String>) -> axum::Json<Value> {
        axum::Json(json!({
            "next": "",
            "results": [{
                "id": "fake-1",
                "content_description": "a cat waving",
                "media_formats": {
                    "tinygif": {"url": format!("{base}/preview.gif"), "dims": [220, 165], "size": 1},
                    "gif": {"url": format!("{base}/full.gif"), "dims": [498, 373], "size": 2}
                }
            }]
        }))
    }
    async fn trending(State(base): State<String>) -> axum::Json<Value> {
        axum::Json(json!({
            "next": "",
            "results": [{
                "id": "fake-trending-1",
                "content_description": "a trending waffle",
                "media_formats": {
                    "tinygif": {"url": format!("{base}/preview.gif"), "dims": [220, 165], "size": 1},
                    "gif": {"url": format!("{base}/full.gif"), "dims": [498, 373], "size": 2}
                }
            }]
        }))
    }
    async fn image() -> impl axum::response::IntoResponse {
        let mut bytes = b"GIF89a".to_vec();
        bytes.extend(std::iter::repeat_n(0u8, 8));
        ([(axum::http::header::CONTENT_TYPE, "image/gif")], bytes)
    }
    // An OpenGraph page for the link-preview pass; og:image is this server's gif.
    async fn page(State(base): State<String>) -> axum::response::Html<String> {
        axum::response::Html(format!(
            "<html><head>\
             <meta property=\"og:title\" content=\"A cat waving\">\
             <meta property=\"og:description\" content=\"A fake page for the contract test\">\
             <meta property=\"og:image\" content=\"{base}/preview.gif\">\
             <meta property=\"og:site_name\" content=\"Fake\">\
             </head><body>hi</body></html>"
        ))
    }

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{addr}");
    let router = Router::new()
        .route("/v2/search", get(search))
        .route("/v2/featured", get(trending))
        .route("/preview.gif", get(image))
        .route("/full.gif", get(image))
        .route("/page", get(page))
        .with_state(base.clone());
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    base
}

/// A fake addons repo the Dock pass installs from, standing in for
/// raw.githubusercontent.com; `Dock::for_test` points the host allowlist at
/// whatever this binds to. One module, `code-exec`, with the same shape the
/// real registry publishes (see docs/decisions/0021 and
/// `http::dock::manifest`'s own tests).
async fn spawn_fake_dock_registry() -> String {
    async fn index() -> axum::Json<Value> {
        axum::Json(json!({
            "schema": 1,
            "modules": [
                {"id": "code-exec", "name": "Code Blocks", "version": "0.1.0", "summary": "runs code"}
            ]
        }))
    }
    async fn manifest() -> axum::Json<Value> {
        let sha256 = wasm_fixtures::sha256_hex(&wasm_fixtures::canned_ok_wasm("done"));
        axum::Json(json!({
            "schema": 1,
            "id": "code-exec",
            "name": "Code Blocks",
            "version": "0.1.0",
            "summary": "runs code",
            "author": "slim-m",
            "artifact": {
                "kind": "wasm",
                "path": "modules/code-exec/0.1.0/module.wasm",
                "sha256": sha256
            },
            "runtime": {
                "backend": "wasm",
                "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}
            },
            "permissions": [
                {"key": "run", "name": "Execute code blocks", "description": "run a snippet"}
            ],
            "capabilities": ["command.register", "message.post", "net.fetch", "schedule", "events", "data.store"],
            "addon_api": 1,
            "subscriptions": [{"event": "member.joined"}],
            "data": {"max_mb": 8, "tables": [{"name": "xp", "columns": [{"name": "user_id", "type": "text", "unique": true}]}]},
            "settings": [
                {"key": "xp_per_minute", "type": "int", "label": "XP per minute", "default": 5, "min": 0, "max": 100},
                {"key": "api_key", "type": "secret", "label": "API key"}
            ],
            "slots": [{"kind": "member.badge", "name": "level", "title": "Level"}],
            "network": {"hosts": ["api.example.com"], "local": false},
            "schedules": [{"command": "run", "every_minutes": 60}],
            "extension_points": [
                {"kind": "command", "name": "run", "description": "runs it", "permission": "run"},
                {"kind": "code-block-runner", "name": "Run in chat", "description": "offers Run on a fenced code block", "permission": "run", "command": "run", "language": "javascript"},
                {"kind": "app", "name": "Code App", "description": "launch it as a surface", "permission": "run", "command": "run"}
            ]
        }))
    }
    async fn artifact() -> Vec<u8> {
        wasm_fixtures::canned_ok_wasm("done")
    }

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{addr}/");
    let router = Router::new()
        .route("/index.json", get(index))
        .route("/modules/code-exec/manifest.json", get(manifest))
        .route("/modules/code-exec/0.1.0/module.wasm", get(artifact));
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    base
}
