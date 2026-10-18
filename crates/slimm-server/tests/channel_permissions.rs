// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /channels/{channel_id}/permissions`: the answer has to match
//! `Store::permissions_in_channel` exactly, including its thread resolution,
//! its DM branch, and its timeout subtraction, and it has to mask to zero
//! whenever the caller lacks VIEW_CHANNEL, or a fabricated channel id would
//! read differently from a real one the caller cannot view. See
//! docs/decisions/0011-per-channel-permissions.md.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_id_token as register};

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn request(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn general_channel_id(store: &Store) -> ChannelId {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .next()
        .expect("bootstrap seeds a general channel")
        .id
}

async fn everyone_role_id(store: &Store) -> Uuid {
    store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .expect("bootstrap seeds @everyone")
        .id
        .0
}

async fn permissions_of(app: &Router, channel_id: ChannelId, token: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request(
            &format!("/channels/{channel_id}/permissions"),
            token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

/// The route's answer has to agree with `permissions_in_channel`, including
/// the timeout subtraction it applies on top of the raw grant - the one
/// thing `granted_permissions_in_channel` would skip.
#[tokio::test]
async fn matches_permissions_in_channel_with_a_timeout_subtracted() {
    let (store, _guard) = new_store("slimm-channel-perms-timeout").await;
    let app = app(store.clone());
    let (_admin_id, admin_token) = register(&store, "alice").await;
    let (member_id, member_token) = register(&store, "bob").await;
    let channel_id = general_channel_id(&store).await;

    let before = permissions_of(&app, channel_id, &member_token).await;
    let before_bits = Permissions::from_bits(before["permissions"].as_i64().unwrap());
    assert!(before_bits.contains(Permissions::SEND_MESSAGES));

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    store
        .set_member_timeout(member_id, now + 60_000, Some("cool off"), member_id)
        .await
        .unwrap();

    let after = permissions_of(&app, channel_id, &member_token).await;
    let after_bits = Permissions::from_bits(after["permissions"].as_i64().unwrap());
    assert!(
        after_bits.contains(Permissions::VIEW_CHANNEL),
        "a timeout must never remove reading"
    );
    assert!(
        !after_bits.contains(Permissions::SEND_MESSAGES),
        "a timeout must remove sending, or the route disagrees with the evaluator"
    );

    let _ = admin_token;
}

/// A thread has no overwrites of its own; the route has to resolve it to its
/// parent, the same as every other permission check in this API. Denying
/// SEND_MESSAGES on the parent via an `@everyone` overwrite is what makes
/// this a real test rather than one two default, overwrite-free channels
/// would pass by accident: the caller is the plain member, never the
/// administrator ADMINISTRATOR would bypass the deny for.
#[tokio::test]
async fn a_thread_answers_exactly_like_its_parent_channel() {
    let (store, _guard) = new_store("slimm-channel-perms-thread").await;
    let app = app(store.clone());
    let (admin_id, admin_token) = register(&store, "alice").await;
    let (_member_id, member_token) = register(&store, "bob").await;
    let channel_id = general_channel_id(&store).await;
    let everyone = everyone_role_id(&store).await;

    let parent_message = store
        .send_message(NewMessage::plain(
            channel_id,
            admin_id,
            MessageId::generate(),
            "start a thread here",
        ))
        .await
        .unwrap()
        .message;
    let thread = store
        .open_thread(channel_id, parent_message.id)
        .await
        .unwrap();
    store
        .set_role_overwrite(
            channel_id,
            slimm_server::ids::RoleId(everyone),
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();

    let parent_answer = permissions_of(&app, channel_id, &member_token).await;
    let thread_answer = permissions_of(&app, thread.channel.id, &member_token).await;
    assert_eq!(
        parent_answer, thread_answer,
        "a thread's own id must answer exactly like its parent's"
    );
    let bits = Permissions::from_bits(parent_answer["permissions"].as_i64().unwrap());
    assert!(
        !bits.contains(Permissions::SEND_MESSAGES),
        "the parent's own deny must actually apply, or this test would pass vacuously"
    );

    let _ = admin_token;
}

/// The property the masking rule exists for: a fabricated channel id and a
/// real channel the caller cannot view answer byte-identically, even though
/// the caller's base grants a bit (SEND_MESSAGES, via `@everyone`) that no
/// overwrite here touches - so an unmasked pass-through would tell the two
/// cases apart and leak that the real channel exists.
#[tokio::test]
async fn a_fabricated_channel_and_an_unviewable_real_one_answer_identically() {
    let (store, _guard) = new_store("slimm-channel-perms-mask").await;
    let app = app(store.clone());
    let (admin_id, _admin_token) = register(&store, "alice").await;
    let (_member_id, member_token) = register(&store, "bob").await;
    let everyone = everyone_role_id(&store).await;

    let hidden = store.create_channel("hidden", "text").await.unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            slimm_server::ids::RoleId(everyone),
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let fabricated = ChannelId(Uuid::now_v7());
    let fabricated_answer = permissions_of(&app, fabricated, &member_token).await;
    let hidden_answer = permissions_of(&app, hidden.id, &member_token).await;

    assert_eq!(
        fabricated_answer, hidden_answer,
        "a nonexistent channel must not be distinguishable from a real one the caller cannot view"
    );
    assert_eq!(fabricated_answer["permissions"], 0);

    let _ = admin_id;
}

/// A DM never runs through the role/overwrite evaluator, so ADMINISTRATOR -
/// which bypasses everything else in this API on purpose - must not reach a
/// DM its holder was never a participant of. `MANAGE_MESSAGES` is what the
/// report-card "Delete message" quick action gates on, so this is the exact
/// scenario decision 0011 names as the sharpest finding.
#[tokio::test]
async fn a_dm_channel_never_grants_manage_messages_even_to_an_administrator() {
    let (store, _guard) = new_store("slimm-channel-perms-dm").await;
    let app = app(store.clone());
    let (admin_id, admin_token) = register(&store, "alice").await;
    let (member_id, _member_token) = register(&store, "bob").await;

    let dm = store.open_dm(admin_id, member_id).await.unwrap();

    let answer = permissions_of(&app, dm.id, &admin_token).await;
    let bits = Permissions::from_bits(answer["permissions"].as_i64().unwrap());
    assert!(bits.contains(Permissions::VIEW_CHANNEL));
    assert!(
        !bits.contains(Permissions::MANAGE_MESSAGES),
        "a DM must never carry MANAGE_MESSAGES, administrator or not"
    );
}
