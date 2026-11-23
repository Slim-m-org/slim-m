// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connector declaring a command and a panel, installed and listening on its
//! own socket, and a member who holds the command's permission.

use std::net::SocketAddr;

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use super::harness::{ID, World, manifest, world};
use crate::support;
use support::app::{Account, call};
use support::ws::Client;

pub const VIEW: i64 = Permissions::VIEW_CHANNEL.bits();
pub const SEND: i64 = VIEW | Permissions::SEND_MESSAGES.bits();

/// The harness manifest plus a `servers` command, its slash command and a panel.
pub fn with_surfaces() -> Value {
    let mut doc = manifest(&["view_channel", "send_messages"]);
    doc["permissions"] = json!([{"key": "use", "name": "Use", "description": "see the servers"}]);
    doc["extension_points"] = json!([
        {"kind": "command", "name": "servers", "permission": "use"},
        {"kind": "slash-command", "name": "servers", "permission": "use", "command": "servers"},
        {"kind": "panel", "name": "Servers", "permission": "use", "command": "servers"}
    ]);
    doc
}

pub struct Live {
    pub w: World,
    pub addr: SocketAddr,
    pub token: String,
    pub member: Account,
}

/// Installs the connector approving `approved`, and a member allowed to run its command.
pub async fn live(name: &str, approved: i64) -> Live {
    let w = world(name, &["view_channel", "send_messages"]).await;
    *w.served.lock().unwrap() = with_surfaces();
    let token = w.installed(approved).await;
    let member = support::app::register_account(&w.store, "member").await;
    let role = w
        .store
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(member.id, role).await.unwrap();
    w.store
        .grant_module_permission(role, ID, "use")
        .await
        .unwrap();
    let addr = support::ws::serve(w.state.clone()).await;
    Live {
        w,
        addr,
        token,
        member,
    }
}

impl Live {
    /// The connector's own socket, opened with its token.
    pub async fn connect(&self) -> Client {
        let (status, body) = call(
            &self.w.router,
            "POST",
            "/auth/ws-ticket",
            Some(&self.token),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        support::ws::connect(self.addr, body["ticket"].as_str().unwrap()).await
    }

    /// The member runs `servers` with `body`; the status and answer.
    pub async fn run(&self, body: Value) -> (StatusCode, Value) {
        call(
            &self.w.router,
            "POST",
            &format!("/modules/{ID}/commands/servers"),
            Some(&self.member.token),
            Some(body),
        )
        .await
    }

    /// The connector answers run `run_id` with `answer`, as `token`.
    pub async fn answer(&self, token: &str, run_id: &str, answer: Value) -> StatusCode {
        call(
            &self.w.router,
            "POST",
            &format!("/connectors/me/runs/{run_id}"),
            Some(token),
            Some(answer),
        )
        .await
        .0
    }
}

/// The next `connector.run` frame on `ws`, or `None` when none comes in a short window.
pub async fn next_run(ws: &mut Client) -> Option<Value> {
    support::ws::wait_for_frame(ws, "connector.run", std::time::Duration::from_secs(3)).await
}
