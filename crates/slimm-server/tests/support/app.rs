// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The shared test harness for HTTP and WebSocket integration tests: the
//! `AppState` builder, request and response helpers, account fixtures and a
//! ready-made deployment with an admin and a member.
//!
//! Start from [`TestApp::start`] for a whole deployment, or from [`state`] /
//! [`builder`] / [`router`] when a test owns its own store. Accounts are made
//! straight through the store, never `/auth/register`: joining a claimed
//! deployment is an invite-gated policy pinned by `registration_gate.rs`.
//!
//! Allowed dead: `mod.rs` pulls this module into every integration test
//! binary and each uses a different slice of it.
#![allow(dead_code)]

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::code_runner::CodeRunner;
use slimm_server::http::dock::Dock;
use slimm_server::http::gifs::GifSearch;
use slimm_server::http::link_preview::LinkPreviews;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
use slimm_server::media::Media;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

/// An `AppState` with every optional service disabled; override with the setters.
pub struct StateBuilder(AppState);

macro_rules! setter {
    ($name:ident, $ty:ty) => {
        pub fn $name(mut self, $name: $ty) -> Self {
            self.0.$name = $name;
            self
        }
    };
}

impl StateBuilder {
    setter!(auth, Auth);
    setter!(hub, Hub);
    setter!(limiter, RateLimiter);
    setter!(push, PushSender);
    setter!(voice, VoiceService);
    setter!(media, Media);
    setter!(gifs, GifSearch);
    setter!(link_previews, LinkPreviews);
    setter!(dock, Dock);
    setter!(code_runner, CodeRunner);

    pub fn build(self) -> AppState {
        self.0
    }

    pub fn router(self) -> Router {
        http::router(self.0)
    }
}

pub fn builder(store: Store) -> StateBuilder {
    StateBuilder(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: GifSearch::disabled(),
        link_previews: LinkPreviews::disabled(),
        dock: Dock::disabled(),
        code_runner: CodeRunner::disabled(),
    })
}

pub fn state(store: Store) -> AppState {
    builder(store).build()
}

pub fn router(store: Store) -> Router {
    builder(store).router()
}

/// The shorthand most files import as `app`.
pub fn app(store: Store) -> Router {
    router(store)
}

pub fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

/// A request that carries a bearer token and an optional JSON body.
pub fn request_authed(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    request(method, uri, Some(token), body)
}

/// A bodiless request with an optional bearer token.
pub fn request_bare(method: &str, uri: &str, token: Option<&str>) -> Request<Body> {
    request(method, uri, token, None)
}

/// A bodiless request with a bearer token.
pub fn request_bearer(method: &str, uri: &str, token: &str) -> Request<Body> {
    request(method, uri, Some(token), None)
}

/// A request with a bearer token and a JSON body.
pub fn request_json(method: &str, uri: &str, token: &str, body: Value) -> Request<Body> {
    request(method, uri, Some(token), Some(body))
}

pub async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// [`json_body`] for responses that may carry no JSON at all, as `Null`.
pub async fn json_body_or_null(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

/// Sends one request through `app` and returns its status and JSON body.
pub async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(method, uri, token, body))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body_or_null(response).await)
}

/// [`call`] for a signed-in caller.
pub async fn call_as(
    app: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    call(app, method, uri, Some(token), body).await
}

pub struct Account {
    pub id: UserId,
    pub token: String,
}

/// A signed-in account; the first one through claims the deployment.
pub async fn register_account(store: &Store, username: &str) -> Account {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    Account {
        id: account.id,
        token: tokens.access_token,
    }
}

/// [`register_account`], returning only the access token.
pub async fn register_token(store: &Store, username: &str) -> String {
    register_account(store, username).await.token
}

/// [`register_account`], returning `(access token, id as a string)`.
pub async fn register_token_id(store: &Store, username: &str) -> (String, String) {
    let account = register_account(store, username).await;
    (account.token, account.id.to_string())
}

/// [`register_account`], returning `(id, access token)`.
pub async fn register_id_token(store: &Store, username: &str) -> (UserId, String) {
    let account = register_account(store, username).await;
    (account.id, account.token)
}

/// An account with no session, for tests that never authenticate it.
pub async fn register_id(store: &Store, username: &str) -> UserId {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    account.id
}

pub async fn general_channel_id(store: &Store) -> String {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .next()
        .expect("bootstrap seeds a general channel")
        .id
        .to_string()
}

/// A deployment with its router, an admin (the claimant) and a member.
pub struct TestApp {
    pub store: Store,
    pub router: Router,
    pub admin: Account,
    pub member: Account,
    _db: super::TestDbGuard,
}

impl TestApp {
    pub async fn start(prefix: &str) -> Self {
        Self::start_with(prefix, |state| state).await
    }

    /// Like [`TestApp::start`], overriding services before the router is built.
    pub async fn start_with(
        prefix: &str,
        configure: impl FnOnce(StateBuilder) -> StateBuilder,
    ) -> Self {
        let (store, db) = super::new_store(prefix).await;
        let admin = register_account(&store, "admin").await;
        let member = register_account(&store, "member").await;
        let router = configure(builder(store.clone())).router();
        Self {
            store,
            router,
            admin,
            member,
            _db: db,
        }
    }

    pub async fn call(
        &self,
        method: &str,
        uri: &str,
        token: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        call(&self.router, method, uri, Some(token), body).await
    }

    pub async fn general_channel(&self) -> String {
        general_channel_id(&self.store).await
    }

    pub async fn create_channel(&self, name: &str) -> String {
        let (status, body) = self
            .call(
                "POST",
                "/channels",
                &self.admin.token,
                Some(json!({ "name": name })),
            )
            .await;
        assert!(status.is_success(), "create channel: {status} {body}");
        body["id"].as_str().unwrap().to_owned()
    }

    pub async fn create_role(&self, name: &str, permissions: i64) -> String {
        let (status, body) = self
            .call(
                "POST",
                "/roles",
                &self.admin.token,
                Some(json!({ "name": name, "permissions": permissions })),
            )
            .await;
        assert!(status.is_success(), "create role: {status} {body}");
        body["id"].as_str().unwrap().to_owned()
    }
}
