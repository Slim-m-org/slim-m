// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connected bot can tell an account deletion from a reversible removal: both arrive as
//! `member.removed`, and only a deletion carries `deleted: true`, so a bot purges what it
//! stores for that member only when the account is really gone.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::app::request_authed as request;
use support::ws::{Client, connect, read_frame_of_type, serve};

struct World {
    store: Store,
    app: axum::Router,
    bot_ws: Client,
    admin_token: String,
    _guard: support::TestDbGuard,
}

async fn member(store: &Store, name: &str) -> (UserId, String) {
    let hash = Auth::new(2)
        .unwrap()
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let user = store.create_account(name, name, &hash).await.unwrap();
    let token = store
        .open_session(user.id, "cli")
        .await
        .unwrap()
        .access_token;
    (user.id, token)
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-account-deletion-bot-frame").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let admin_token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;
    let bot = store
        .create_bot("keeper", "Keeper", Permissions::NONE, admin.id)
        .await
        .unwrap();
    let ctx = store.authenticate_bot(&bot.token).await.unwrap().unwrap();
    let (ticket, _) = store.mint_ws_ticket(&ctx).await.unwrap();
    let state = support::app::state(store.clone());
    let app = slimm_server::http::router(state.clone());
    let bot_ws = connect(serve(state).await, &ticket).await;
    World {
        store,
        app,
        bot_ws,
        admin_token,
        _guard: guard,
    }
}

async fn send(w: &World, method: &str, uri: &str, token: &str, body: Option<Value>) {
    let response = w
        .app
        .clone()
        .oneshot(request(method, uri, token, body))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT, "{method} {uri}");
}

async fn removal_frame_for(w: &mut World, user: UserId) -> Value {
    loop {
        let frame = read_frame_of_type(&mut w.bot_ws, "member.removed").await;
        if frame["user_id"] == user.to_string() {
            return frame;
        }
    }
}

#[tokio::test]
async fn a_removal_reaches_a_bot_without_the_deleted_flag() {
    let mut w = world().await;
    let (alice, _) = member(&w.store, "alice").await;
    let uri = format!("/members/{alice}/removal");
    send(&w, "PUT", &uri, &w.admin_token.clone(), Some(json!({}))).await;
    let frame = removal_frame_for(&mut w, alice).await;
    assert!(frame.get("deleted").is_none(), "{frame}");
}

#[tokio::test]
async fn an_admin_account_deletion_reaches_a_bot_as_deleted() {
    let mut w = world().await;
    let (bob, _) = member(&w.store, "bob").await;
    let uri = format!("/members/{bob}/account");
    send(&w, "DELETE", &uri, &w.admin_token.clone(), None).await;
    let frame = removal_frame_for(&mut w, bob).await;
    assert_eq!(frame["deleted"], true, "{frame}");
}

#[tokio::test]
async fn a_self_account_deletion_reaches_a_bot_as_deleted() {
    let mut w = world().await;
    let (carol, token) = member(&w.store, "carol").await;
    let body = Some(json!({"password": "hunter2hunter2"}));
    send(&w, "DELETE", "/account", &token, body).await;
    let frame = removal_frame_for(&mut w, carol).await;
    assert_eq!(frame["deleted"], true, "{frame}");
}
