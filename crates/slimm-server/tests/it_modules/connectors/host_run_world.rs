// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deployment whose Dock offers one host-run connector and talks to a fake supervisor.

use std::sync::{Arc, Mutex};

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::http::AppState;
use slimm_server::http::connector_host::{HostRunner, SupervisorClient};
use slimm_server::http::dock::Dock;
use slimm_server::store::Store;

use super::fake_supervisor::{self, Fake, SECRET, SocketGuard};
use super::harness::{ID, manifest, registry};
use crate::support;
use support::app::{Account, call};

pub const IMAGE: &str = "ghcr.io/slim-m-org/jellyfin@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
pub const SEND: i64 = slimm_server::permissions::Permissions::VIEW_CHANNEL.bits()
    | slimm_server::permissions::Permissions::SEND_MESSAGES.bits();

pub fn host_run_manifest() -> Value {
    let mut doc = manifest(&["view_channel", "send_messages"]);
    doc["connector"]["host_run"] = json!({
        "image": IMAGE,
        "egress": [{"host": "api.example.com", "port": 443}, {"host": "jellyfin.lan", "port": 8096}],
        "egress_private": true,
        "volume": true,
        "limits": {"memory_mib": 64, "pids": 32}
    });
    doc
}

pub struct HostWorld {
    pub store: Store,
    pub pool: sqlx::SqlitePool,
    pub state: AppState,
    pub router: Router,
    pub owner: Account,
    pub fake: Fake,
    pub socket: std::path::PathBuf,
    _socket: SocketGuard,
    _guard: support::TestDbGuard,
}

/// `supervisor` false leaves the operator's supervisor unset; `serving` false leaves the
/// configured socket with nothing behind it, as when the supervisor is down.
pub async fn host_world(name: &str, supervisor: bool, serving: bool) -> HostWorld {
    let (store, pool, guard) = support::new_store_with_pool(name).await;
    let owner = support::app::register_account(&store, "owner").await;
    let served = Arc::new(Mutex::new(host_run_manifest()));
    let base = registry(served.clone()).await;
    let socket = fake_supervisor::socket_path();
    let fake = Fake::default();
    if serving {
        fake_supervisor::serve(fake.clone(), &socket).await;
    }
    let runner = supervisor.then(|| {
        HostRunner::new(
            SupervisorClient::new(&socket, SECRET.to_owned()),
            "http://server:8080".into(),
        )
    });
    let state = support::app::builder(store.clone())
        .dock(Dock::for_test(&base).with_connector_runtime(runner))
        .build();
    slimm_server::http::connector_host::tick(&state).await;
    HostWorld {
        router: slimm_server::http::router(state.clone()),
        store,
        pool,
        state,
        owner,
        fake,
        socket: socket.clone(),
        _socket: SocketGuard(socket),
        _guard: guard,
    }
}

impl HostWorld {
    pub async fn as_owner(
        &self,
        method: &str,
        uri: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        call(&self.router, method, uri, Some(&self.owner.token), body).await
    }

    /// Installs with `approval` as `approved_host_run`, or none when `Null`.
    pub async fn install(&self, approval: Value) -> (StatusCode, Value) {
        let (status, shown) = self
            .as_owner("GET", &format!("/space/dock/modules/{ID}"), None)
            .await;
        assert_eq!(status, StatusCode::OK, "{shown}");
        let mut body = json!({
            "version": shown["version"],
            "reviewed_digest": shown["review_digest"],
            "approved_connector_permissions": SEND,
        });
        if !approval.is_null() {
            body["approved_host_run"] = approval;
        }
        self.as_owner(
            "POST",
            &format!("/space/dock/modules/{ID}/install"),
            Some(body),
        )
        .await
    }

    /// Installs approving every egress host and the Private network, then enables it.
    pub async fn running(&self) -> String {
        let approval = json!({"egress": [{"host": "api.example.com", "port": 443}, {"host": "jellyfin.lan", "port": 8096}], "egress_private": true});
        let (status, body) = self.install(approval).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let (status, body) = self
            .as_owner("POST", &format!("/space/dock/modules/{ID}/enable"), None)
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        self.run_id().await
    }

    pub async fn run_id(&self) -> String {
        self.store
            .host_run(ID)
            .await
            .unwrap()
            .expect("a host-run row")
            .run_id
    }

    pub async fn status(&self) -> Value {
        let (status, body) = self
            .as_owner("GET", &format!("/space/dock/modules/{ID}/host-run"), None)
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    }

    pub async fn tick(&self) {
        slimm_server::http::connector_host::tick(&self.state).await;
    }

    /// The token the last create handed the container.
    pub fn last_token(&self) -> String {
        let creates = self.fake.calls("create");
        let (_, body) = creates.last().expect("a create");
        body["env"]["SLIMM_TOKEN"].as_str().unwrap().to_owned()
    }
}
