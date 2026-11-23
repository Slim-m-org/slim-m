// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deployment whose Dock reads a fake registry serving one connector
//! manifest, its owner, and helpers that install the connector and act with
//! its token.

use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::get;
use serde_json::{Value, json};
use slimm_server::http::AppState;
use slimm_server::http::dock::Dock;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use uuid::Uuid;

use crate::support;
use support::app::{Account, call};

pub const ID: &str = "jellyfin";

/// A connector manifest asking for `permissions`.
pub fn manifest(permissions: &[&str]) -> Value {
    json!({
        "schema": 1,
        "id": ID,
        "name": "Jellyfin",
        "version": "0.1.0",
        "summary": "posts what is playing",
        "provider": "connector",
        "addon_api": 7,
        "connector": {"permissions": permissions},
        "settings": [
            {"key": "server_url", "type": "string", "label": "Server address", "default": "http://jellyfin:8096"},
            {"key": "api_key", "type": "secret", "label": "API key"}
        ]
    })
}

pub struct World {
    pub state: AppState,
    pub store: Store,
    pub pool: SqlitePool,
    pub router: Router,
    pub owner: Account,
    pub served: Arc<Mutex<Value>>,
    _guard: support::TestDbGuard,
}

async fn registry(served: Arc<Mutex<Value>>) -> String {
    let router = Router::new()
        .route(
            "/index.json",
            get(|| async {
                axum::Json(json!({"schema": 1, "modules": [
                    {"id": ID, "name": "Jellyfin", "version": "0.1.0", "summary": "posts what is playing"}
                ]}))
            }),
        )
        .route(
            &format!("/modules/{ID}/manifest.json"),
            get(|State(s): State<Arc<Mutex<Value>>>| async move {
                axum::Json(s.lock().unwrap().clone())
            }),
        )
        .with_state(served);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    base
}

pub async fn world(name: &str, permissions: &[&str]) -> World {
    let (store, pool, guard) = support::new_store_with_pool(name).await;
    let owner = support::app::register_account(&store, "owner").await;
    let served = Arc::new(Mutex::new(manifest(permissions)));
    let base = registry(served.clone()).await;
    let state = support::app::builder(store.clone())
        .dock(Dock::for_test(&base))
        .build();
    let router = slimm_server::http::router(state.clone());
    World {
        state,
        store,
        pool,
        router,
        owner,
        served,
        _guard: guard,
    }
}

impl World {
    pub async fn as_owner(
        &self,
        method: &str,
        uri: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        call(&self.router, method, uri, Some(&self.owner.token), body).await
    }

    pub async fn as_token(
        &self,
        token: &str,
        method: &str,
        uri: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        call(&self.router, method, uri, Some(token), body).await
    }

    /// The manifest as the Dock shows it, then an install approving `approved` bits.
    pub async fn install(&self, approved: Option<i64>) -> (StatusCode, Value) {
        let (status, shown) = self
            .as_owner("GET", &format!("/space/dock/modules/{ID}"), None)
            .await;
        assert_eq!(status, StatusCode::OK, "{shown}");
        let mut body = json!({
            "version": shown["version"],
            "reviewed_digest": shown["review_digest"],
        });
        if let Some(bits) = approved {
            body["approved_connector_permissions"] = json!(bits);
        }
        self.as_owner(
            "POST",
            &format!("/space/dock/modules/{ID}/install"),
            Some(body),
        )
        .await
    }

    /// Installs approving `approved`, enables it, and answers its token.
    pub async fn installed(&self, approved: i64) -> String {
        let (status, body) = self.install(Some(approved)).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let token = body["connector_token"]
            .as_str()
            .expect("a first install shows the token");
        self.set_enabled(true).await;
        token.to_owned()
    }

    pub async fn set_enabled(&self, enabled: bool) {
        let verb = if enabled { "enable" } else { "disable" };
        let (status, body) = self
            .as_owner("POST", &format!("/space/dock/modules/{ID}/{verb}"), None)
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }

    pub async fn general(&self) -> String {
        support::app::general_channel_id(&self.store).await
    }

    /// Posts in `channel` with `token`; the status.
    pub async fn post(&self, token: &str, channel: &str) -> StatusCode {
        let body = json!({"id": Uuid::now_v7().to_string(), "content": "now playing"});
        self.as_token(
            token,
            "POST",
            &format!("/channels/{channel}/messages"),
            Some(body),
        )
        .await
        .0
    }
}
