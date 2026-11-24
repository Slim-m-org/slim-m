// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every way a session is revoked closes the socket it holds: refresh-token replay, a second
//! sign-in on the same install, and the revoke-all paths for a session revoked earlier.

use std::time::Duration;

use axum::Router;
use axum::http::StatusCode;
use futures_util::StreamExt;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http;
use slimm_server::ids::UserId;
use slimm_server::store::{RefreshOutcome, Store};
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::support;
use support::app::call;
use support::ws::{Client, connect, serve};

const PASSWORD: &str = "correct-horse-battery";
const INSTALL: &str = "install-0001";

struct World {
    store: Store,
    router: Router,
    addr: std::net::SocketAddr,
    admin_token: String,
    member: UserId,
    _db: support::TestDbGuard,
}

impl World {
    async fn start() -> Self {
        let (store, db) = support::new_store("slimm-revoked-sockets").await;
        let state = support::app::state(store.clone());
        let hash = Auth::new(2)
            .unwrap()
            .hash_password(PASSWORD.to_owned())
            .await
            .unwrap();
        let admin = store.create_account("root", "Root", &hash).await.unwrap();
        store.bootstrap_deployment(admin.id).await.unwrap();
        let admin_token = store
            .open_session(admin.id, "cli")
            .await
            .unwrap()
            .access_token;
        let member = store.create_account("alice", "Alice", &hash).await.unwrap();
        let addr = serve(state.clone()).await;
        Self {
            router: http::router(state.clone()),
            store,
            addr,
            admin_token,
            member: member.id,
            _db: db,
        }
    }

    async fn socket_for(&self, access_token: &str) -> Client {
        let ctx = self
            .store
            .authenticate(access_token)
            .await
            .unwrap()
            .expect("a live access token");
        let (ticket, _) = self.store.mint_ws_ticket(&ctx).await.unwrap();
        connect(self.addr, &ticket).await
    }

    async fn login(&self, install_id: Option<&str>) -> Value {
        let body = json!({
            "username": "alice",
            "password": PASSWORD,
            "device_name": "laptop",
            "install_id": install_id,
        });
        let (status, body) = call(&self.router, "POST", "/auth/login", None, Some(body)).await;
        assert_eq!(status, StatusCode::OK, "login: {body}");
        body
    }

    /// Revokes a session in the store alone, as a revocation that published nothing would.
    async fn revoke_quietly(&self, access_token: &str) {
        let ctx = self
            .store
            .authenticate(access_token)
            .await
            .unwrap()
            .unwrap();
        self.store.revoke_session(ctx.session_id).await.unwrap();
    }
}

async fn closes(ws: &mut Client, within: Duration) -> bool {
    let wait = async {
        loop {
            match ws.next().await {
                None | Some(Ok(WsMessage::Close(_)) | Err(_)) => return,
                Some(Ok(_)) => {}
            }
        }
    };
    tokio::time::timeout(within, wait).await.is_ok()
}

const CLOSE_WITHIN: Duration = Duration::from_secs(2);
const STAYS_FOR: Duration = Duration::from_millis(400);

#[tokio::test]
async fn a_replayed_refresh_token_closes_the_original_socket() {
    let world = World::start().await;
    let first = world
        .store
        .open_session(world.member, "laptop")
        .await
        .unwrap();
    let RefreshOutcome::Rotated(rotated) = world
        .store
        .rotate_refresh(&first.refresh_token)
        .await
        .unwrap()
    else {
        panic!("a fresh refresh token rotates");
    };
    let mut ws = world.socket_for(&rotated.access_token).await;

    let replay = json!({ "refresh_token": first.refresh_token });
    let (status, _) = call(&world.router, "POST", "/auth/refresh", None, Some(replay)).await;

    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(
        closes(&mut ws, CLOSE_WITHIN).await,
        "the session a replay revoked must lose its socket"
    );
}

#[tokio::test]
async fn signing_in_again_on_the_same_install_closes_the_earlier_socket() {
    let world = World::start().await;
    let first = world.login(Some(INSTALL)).await;
    let mut ws = world
        .socket_for(first["access_token"].as_str().unwrap())
        .await;

    world.login(Some(INSTALL)).await;

    assert!(
        closes(&mut ws, CLOSE_WITHIN).await,
        "the session the second sign-in replaced must lose its socket"
    );
}

#[tokio::test]
async fn a_password_change_closes_a_socket_on_a_session_revoked_earlier() {
    let world = World::start().await;
    let stolen = world
        .store
        .open_session(world.member, "laptop")
        .await
        .unwrap();
    let own = world
        .store
        .open_session(world.member, "phone")
        .await
        .unwrap();
    let mut stolen_ws = world.socket_for(&stolen.access_token).await;
    let mut own_ws = world.socket_for(&own.access_token).await;
    world.revoke_quietly(&stolen.access_token).await;

    let body = json!({ "current_password": PASSWORD, "new_password": "a-brand-new-password" });
    let (status, body) = call(
        &world.router,
        "POST",
        "/auth/password",
        Some(&own.access_token),
        Some(body),
    )
    .await;

    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    assert!(
        closes(&mut stolen_ws, CLOSE_WITHIN).await,
        "a socket left on an already revoked session must close"
    );
    assert!(
        !closes(&mut own_ws, STAYS_FOR).await,
        "the session that changed the password keeps its socket"
    );
}

#[tokio::test]
async fn a_reset_code_closes_a_socket_on_a_session_revoked_earlier() {
    let world = World::start().await;
    let stolen = world
        .store
        .open_session(world.member, "laptop")
        .await
        .unwrap();
    let mut ws = world.socket_for(&stolen.access_token).await;
    world.revoke_quietly(&stolen.access_token).await;
    let uri = format!("/admin/users/{}/reset-code", world.member);
    let admin = Some(world.admin_token.as_str());
    let reauth = Some(json!({ "password": PASSWORD }));
    let (status, issued) = call(&world.router, "POST", &uri, admin, reauth).await;
    assert!(status.is_success(), "issue a reset code: {status} {issued}");

    let body = json!({ "code": issued["code"], "new_password": "a-brand-new-password" });
    let (status, body) = call(&world.router, "POST", "/auth/reset", None, Some(body)).await;

    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    assert!(closes(&mut ws, CLOSE_WITHIN).await);
}

#[tokio::test]
async fn removing_a_member_closes_a_socket_on_a_session_revoked_earlier() {
    let world = World::start().await;
    let stolen = world
        .store
        .open_session(world.member, "laptop")
        .await
        .unwrap();
    let mut ws = world.socket_for(&stolen.access_token).await;
    world.revoke_quietly(&stolen.access_token).await;

    let uri = format!("/members/{}/removal", world.member);
    let admin = Some(world.admin_token.as_str());
    let (status, body) = call(&world.router, "PUT", &uri, admin, Some(json!({}))).await;

    assert!(status.is_success(), "remove the member: {status} {body}");
    assert!(closes(&mut ws, CLOSE_WITHIN).await);
}
