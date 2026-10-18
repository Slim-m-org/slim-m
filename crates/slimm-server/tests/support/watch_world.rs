// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deployment with a voice channel, two bots on its call and two members,
//! shared by the watch session test binaries.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

pub struct World {
    pub state: AppState,
    pub pool: sqlx::SqlitePool,
    pub voice: ChannelId,
    pub text: ChannelId,
    pub bot: String,
    pub bot_id: UserId,
    pub other_bot: String,
    pub other_bot_id: UserId,
    pub member: String,
    pub alice: slimm_server::ids::UserId,
    pub bob: String,
    pub _guard: super::TestDbGuard,
}

pub async fn world() -> World {
    let (path, guard) = super::TestDbGuard::new("slimm-watch-session");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool.clone());
    let root = store
        .create_account("root", "root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(root.id).await.unwrap();
    let voice = store.create_channel("lounge", "voice").await.unwrap().id;
    let text = store.create_channel("general", "text").await.unwrap().id;
    let user = store.create_user("alice", "alice").await.unwrap();
    let member = store
        .open_session(user.id, "cli")
        .await
        .unwrap()
        .access_token;
    let bob_user = store.create_user("bob", "bob").await.unwrap();
    let bob = store
        .open_session(bob_user.id, "cli")
        .await
        .unwrap()
        .access_token;
    let jelly = store
        .create_bot("jelly", "Jelly", Permissions::NONE, root.id)
        .await
        .unwrap();
    let other = store
        .create_bot("other", "Other", Permissions::NONE, root.id)
        .await
        .unwrap();
    let state = super::app::builder(store).build();
    for bot in [jelly.bot.user_id, other.bot.user_id] {
        state.voice.record_heartbeat_reporting_new(bot, voice);
    }
    World {
        state,
        pool,
        voice,
        text,
        bot: jelly.token,
        bot_id: jelly.bot.user_id,
        other_bot: other.token,
        other_bot_id: other.bot.user_id,
        member,
        alice: user.id,
        bob,
        _guard: guard,
    }
}

pub async fn call(
    w: &World,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    let request = match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    };
    let response = http::router(w.state.clone())
        .oneshot(request)
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

pub fn film(position_ms: i64, playing: bool) -> Value {
    json!({
        "item_id": "item-1",
        "title": "A Film",
        "duration_ms": 5_400_000,
        "playing": playing,
        "position_ms": position_ms,
    })
}

pub fn session_uri(channel: ChannelId) -> String {
    format!("/channels/{channel}/watch-session")
}
