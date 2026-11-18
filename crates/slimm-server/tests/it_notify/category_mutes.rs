// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `/notification-preferences/categories`: muting a whole category silences every channel under it,
//! sub-categories and channels filed later included, while a channel's own override still wins.

use axum::http::StatusCode;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelCategoryId, ChannelId, DeviceId, UserId};
use slimm_server::notifications::NotificationPreference;
use slimm_server::store::{ChannelDefaults, PushRegistration, Store};
use uuid::Uuid;

use crate::support;
use support::app::{app, call_as, register_id_token};
use support::wake_recipients;

const KEY: [u8; 32] = [7u8; 32];

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

async fn account(store: &Store, username: &str) -> (UserId, DeviceId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "phone").await.unwrap();
    store
        .register_push(
            account.id,
            session.device_id,
            PushRegistration {
                platform: "ios",
                push_token: username,
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();
    (account.id, session.device_id)
}

async fn category(
    store: &Store,
    name: &str,
    parent: Option<ChannelCategoryId>,
) -> ChannelCategoryId {
    store
        .create_category_with_id(ChannelCategoryId::generate(), name, parent)
        .await
        .unwrap()
        .category
        .id
}

async fn channel_in(store: &Store, name: &str, category: ChannelCategoryId) -> ChannelId {
    channel_with(store, name, category, None).await
}

async fn channel_with(
    store: &Store,
    name: &str,
    category: ChannelCategoryId,
    private_to: Option<UserId>,
) -> ChannelId {
    store
        .create_channel_with_id(
            ChannelId::generate(),
            name,
            "text",
            Some(category),
            private_to,
            ChannelDefaults::default(),
        )
        .await
        .unwrap()
        .channel
        .id
}

async fn wakes(store: &Store, channel: ChannelId, author: UserId, reader: UserId) -> bool {
    wake_recipients(store, channel, author, "hello")
        .await
        .unwrap()
        .contains(&reader)
}

#[tokio::test]
async fn a_muted_category_silences_its_channels_sub_categories_and_later_channels() {
    let (store, _guard) = new_store("slimm-category-mute-scope").await;
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let games = category(&store, "games", None).await;
    let retro = category(&store, "retro", Some(games)).await;
    let other = category(&store, "other", None).await;
    let lobby = channel_in(&store, "lobby", games).await;
    let snes = channel_in(&store, "snes", retro).await;
    let elsewhere = channel_in(&store, "elsewhere", other).await;
    assert!(wakes(&store, lobby, bob, alice).await, "nothing muted yet");

    assert!(store.mute_category(alice, games).await.unwrap());
    assert!(
        !store.mute_category(alice, games).await.unwrap(),
        "idempotent"
    );
    let later = channel_in(&store, "later", games).await;

    assert!(
        !wakes(&store, lobby, bob, alice).await,
        "a channel in the muted category"
    );
    assert!(
        !wakes(&store, snes, bob, alice).await,
        "a channel in its sub-category"
    );
    assert!(
        !wakes(&store, later, bob, alice).await,
        "a channel filed after the mute"
    );
    assert!(
        wakes(&store, elsewhere, bob, alice).await,
        "another category stays loud"
    );
    assert!(wakes(&store, lobby, alice, bob).await, "bob muted nothing");

    assert!(store.unmute_category(alice, games).await.unwrap());
    assert!(wakes(&store, lobby, bob, alice).await, "unmuted again");
}

#[tokio::test]
async fn a_muted_sub_category_leaves_its_parent_loud_and_reaches_threads() {
    let (store, _guard) = new_store("slimm-category-mute-sub").await;
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let games = category(&store, "games", None).await;
    let retro = category(&store, "retro", Some(games)).await;
    let lobby = channel_in(&store, "lobby", games).await;
    let snes = channel_in(&store, "snes", retro).await;
    store.mute_category(alice, retro).await.unwrap();

    assert!(
        wakes(&store, lobby, bob, alice).await,
        "the parent is not muted"
    );
    assert!(!wakes(&store, snes, bob, alice).await);

    let root = store
        .send_message(slimm_server::store::NewMessage::plain(
            snes,
            alice,
            slimm_server::ids::MessageId::generate(),
            "root",
        ))
        .await
        .unwrap();
    let thread = store
        .open_thread(snes, root.message.id)
        .await
        .unwrap()
        .channel;
    assert!(
        !wakes(&store, thread.id, bob, alice).await,
        "a thread follows its parent's category"
    );
}

#[tokio::test]
async fn a_channel_override_beats_its_category_mute() {
    let (store, _guard) = new_store("slimm-category-mute-override").await;
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let games = category(&store, "games", None).await;
    let lobby = channel_in(&store, "lobby", games).await;
    store.mute_category(alice, games).await.unwrap();
    store
        .set_channel_notification_preference(alice, lobby, NotificationPreference::Everything)
        .await
        .unwrap();

    assert!(wakes(&store, lobby, bob, alice).await);
}

#[tokio::test]
async fn mute_list_and_unmute_round_trip_over_http() {
    let (store, _guard) = new_store("slimm-category-mute-http").await;
    let app = app(store.clone());
    let (alice, alice_token) = register_id_token(&store, "alice").await;
    let (_bob, bob_token) = register_id_token(&store, "bob").await;
    let games = category(&store, "games", None).await;
    channel_in(&store, "lobby", games).await;
    let secret = category(&store, "secret", None).await;
    channel_with(&store, "hideout", secret, Some(alice)).await;
    let path = format!("/notification-preferences/categories/{games}");

    let (status, body) = call_as(&app, "PUT", &path, &alice_token, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["category_id"], games.to_string());
    let (status, listed) = call_as(
        &app,
        "GET",
        "/notification-preferences/categories",
        &alice_token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        listed,
        serde_json::json!([{ "category_id": games.to_string() }])
    );

    let (status, _) = call_as(&app, "DELETE", &path, &alice_token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, listed) = call_as(
        &app,
        "GET",
        "/notification-preferences/categories",
        &alice_token,
        None,
    )
    .await;
    assert_eq!(listed, serde_json::json!([]));
    let (status, _) = call_as(&app, "DELETE", &path, &alice_token, None).await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "unmuting twice is not an error"
    );

    let unknown = format!("/notification-preferences/categories/{}", Uuid::now_v7());
    let (status, _) = call_as(&app, "PUT", &unknown, &bob_token, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let hidden = format!("/notification-preferences/categories/{secret}");
    let (status, _) = call_as(&app, "PUT", &hidden, &bob_token, None).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "a category bob cannot see reads as missing"
    );
    let (status, _) = call_as(&app, "PUT", &path, &bob_token, None).await;
    assert_eq!(status, StatusCode::OK, "bob can mute a category he can see");
}

#[tokio::test]
async fn a_deleted_category_drops_out_of_the_list() {
    let (store, _guard) = new_store("slimm-category-mute-deleted").await;
    let (alice, _) = account(&store, "alice").await;
    let games = category(&store, "games", None).await;
    store.mute_category(alice, games).await.unwrap();
    assert_eq!(store.list_category_mutes(alice).await.unwrap(), vec![games]);
    store.delete_category(games).await.unwrap();
    assert!(store.list_category_mutes(alice).await.unwrap().is_empty());
}
