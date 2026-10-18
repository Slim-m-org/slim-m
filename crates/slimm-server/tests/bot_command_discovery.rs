// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /channels/{channelId}/bot-commands`: visibility, lifecycle and
//! permission gating. Registration itself is `tests/bot_commands.rs`. See
//! decision 0031.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{
    app, json_body_or_null as json_body, register_id_token as register, request_authed as request,
};

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

async fn everyone_role_id(store: &Store) -> RoleId {
    RoleId(
        store
            .list_roles()
            .await
            .unwrap()
            .into_iter()
            .find(|r| r.is_everyone)
            .expect("bootstrap seeds @everyone")
            .id
            .0,
    )
}

/// A fresh bot, holding only whatever `@everyone` holds - decision 0028's own
/// baseline.
async fn bot(store: &Store, created_by: UserId, username: &str) -> (UserId, String) {
    let new_bot = store
        .create_bot(username, username, Permissions::NONE, created_by)
        .await
        .unwrap();
    (new_bot.bot.user_id, new_bot.token)
}

fn register_body(prefix: &str, commands: Value) -> Value {
    json!({ "prefix": prefix, "commands": commands })
}

async fn channel_commands(app: &Router, channel_id: ChannelId, token: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/bot-commands"),
            token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

#[tokio::test]
async fn a_registered_command_is_offered_in_a_channel_the_bot_can_see() {
    let (store, _guard) = new_store("slimm-botcmds-visible").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let channel = general_channel_id(&store).await;
    let router = app(store);

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "ping", "description": "check if I'm alive" }]),
            )),
        ))
        .await
        .unwrap();

    let commands = channel_commands(&router, channel, &admin_token).await;
    assert_eq!(
        commands,
        json!([{
            "bot_user_id": bot_id.to_string(),
            "bot_username": "helper",
            "bot_display_name": "helper",
            "prefix": "!",
            "name": "ping",
            "description": "check if I'm alive"
        }])
    );
}

/// A bot with no view of a channel must not advertise itself there, even
/// with a live token and Space membership.
#[tokio::test]
async fn a_bot_with_no_view_of_the_channel_does_not_advertise_there() {
    let (store, _guard) = new_store("slimm-botcmds-no-view").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (_bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let hidden = store.create_channel("hidden", "text").await.unwrap();
    let everyone = everyone_role_id(&store).await;
    store
        .set_role_overwrite(
            hidden.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let router = app(store);

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "ping", "description": "d" }]),
            )),
        ))
        .await
        .unwrap();

    let commands = channel_commands(&router, hidden.id, &admin_token).await;
    assert_eq!(
        commands,
        json!([]),
        "the bot itself only holds @everyone here, which this channel denies VIEW_CHANNEL to"
    );
}

/// Revoking a bot's token must make its commands vanish immediately.
#[tokio::test]
async fn a_revoked_bots_commands_vanish_from_discovery() {
    let (store, _guard) = new_store("slimm-botcmds-revoked").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let channel = general_channel_id(&store).await;
    let router = app(store.clone());

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "ping", "description": "d" }]),
            )),
        ))
        .await
        .unwrap();
    assert_ne!(
        channel_commands(&router, channel, &admin_token).await,
        json!([])
    );

    store.revoke_bot(bot_id, admin_id).await.unwrap();

    assert_eq!(
        channel_commands(&router, channel, &admin_token).await,
        json!([]),
        "a revoked bot's commands must disappear immediately"
    );
}

/// Removing a bot from the Space must also make its commands vanish.
#[tokio::test]
async fn a_bot_removed_from_the_space_no_longer_advertises() {
    let (store, _guard) = new_store("slimm-botcmds-removed").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let channel = general_channel_id(&store).await;
    let router = app(store.clone());

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "ping", "description": "d" }]),
            )),
        ))
        .await
        .unwrap();
    assert_ne!(
        channel_commands(&router, channel, &admin_token).await,
        json!([])
    );

    store
        .remove_from_space(bot_id, admin_id, Some("no longer needed"))
        .await
        .unwrap();

    assert_eq!(
        channel_commands(&router, channel, &admin_token).await,
        json!([]),
        "a bot removed from the Space must not keep advertising commands"
    );
}

#[tokio::test]
async fn a_gated_command_is_hidden_from_a_caller_without_the_permission() {
    let (store, _guard) = new_store("slimm-botcmds-gated").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let channel = general_channel_id(&store).await;
    let plain = store.create_user("mallory", "Mallory").await.unwrap();
    let plain_token = store
        .open_session(plain.id, "phone")
        .await
        .unwrap()
        .access_token;
    let router = app(store.clone());

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([
                    { "name": "ping", "description": "open to everyone" },
                    {
                        "name": "purge",
                        "description": "gated",
                        "permission": Permissions::MANAGE_MESSAGES.bits()
                    }
                ]),
            )),
        ))
        .await
        .unwrap();

    let admin_view = channel_commands(&router, channel, &admin_token).await;
    let names: Vec<&str> = admin_view
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"ping"));
    assert!(
        names.contains(&"purge"),
        "the administrator's own MANAGE_MESSAGES should still show the gated command"
    );

    let plain_view = channel_commands(&router, channel, &plain_token).await;
    let names: Vec<&str> = plain_view
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"ping"), "the ungated command stays offered");
    assert!(
        !names.contains(&"purge"),
        "a caller without MANAGE_MESSAGES must not be offered the gated command"
    );
    let _ = bot_id;
}

/// A caller who cannot view the channel must learn nothing about it,
/// including an otherwise-ungated bot command living there.
#[tokio::test]
async fn a_caller_without_view_channel_sees_no_commands() {
    let (store, _guard) = new_store("slimm-botcmds-caller-blind").await;
    let (admin_id, _admin_token) = register(&store, "root").await;
    let (_bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let outsider = store.create_user("outsider", "Outsider").await.unwrap();
    let outsider_token = store
        .open_session(outsider.id, "phone")
        .await
        .unwrap()
        .access_token;
    let hidden = store.create_channel("hidden", "text").await.unwrap();
    let everyone = everyone_role_id(&store).await;
    store
        .set_role_overwrite(
            hidden.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let router = app(store.clone());

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "ping", "description": "d" }]),
            )),
        ))
        .await
        .unwrap();

    assert_eq!(
        channel_commands(&router, hidden.id, &outsider_token).await,
        json!([])
    );
}
