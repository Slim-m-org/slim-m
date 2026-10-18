// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `PUT /bots/commands` and `GET /bots/{botId}/commands`. Discovery-list
//! visibility is `tests/bot_command_discovery.rs`. See decision 0031.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
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

#[tokio::test]
async fn a_bot_with_no_registration_answers_empty_on_its_profile_route() {
    let (store, _guard) = new_store("slimm-botcmds-none").await;
    let (admin_id, _admin_token) = register(&store, "root").await;
    let (bot_id, _bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    let response = router
        .clone()
        .oneshot(request(
            "GET",
            &format!("/bots/{bot_id}/commands"),
            &_admin_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        json_body(response).await,
        json!({ "prefix": null, "commands": [] })
    );
}

#[tokio::test]
async fn a_bot_can_register_and_read_back_its_own_commands() {
    let (store, _guard) = new_store("slimm-botcmds-register").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    let response = router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([
                    { "name": "ping", "description": "check if I'm alive" },
                    { "name": "roll", "description": "roll dice", "usage": "<sides>" }
                ]),
            )),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let response = router
        .oneshot(request(
            "GET",
            &format!("/bots/{bot_id}/commands"),
            &admin_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        json_body(response).await,
        json!({
            "prefix": "!",
            "commands": [
                { "name": "ping", "description": "check if I'm alive" },
                { "name": "roll", "description": "roll dice", "usage": "<sides>" }
            ]
        })
    );
}

#[tokio::test]
async fn registering_again_replaces_the_whole_set() {
    let (store, _guard) = new_store("slimm-botcmds-overwrite").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "old", "description": "the old one" }]),
            )),
        ))
        .await
        .unwrap();

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "new", "description": "the new one" }]),
            )),
        ))
        .await
        .unwrap();

    let response = router
        .oneshot(request(
            "GET",
            &format!("/bots/{bot_id}/commands"),
            &admin_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        json_body(response).await,
        json!({
            "prefix": "!",
            "commands": [{ "name": "new", "description": "the new one" }]
        }),
        "the old command must be gone, not merged with the new set"
    );
}

#[tokio::test]
async fn a_human_cannot_register_bot_commands() {
    let (store, _guard) = new_store("slimm-botcmds-human").await;
    let (_admin_id, admin_token) = register(&store, "root").await;
    let router = app(store);

    let response = router
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &admin_token,
            Some(register_body("!", json!([]))),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_reserved_prefix_is_rejected() {
    let (store, _guard) = new_store("slimm-botcmds-reserved-prefix").await;
    let (admin_id, _admin_token) = register(&store, "root").await;
    let (_bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    for reserved in ["/", "@", ":"] {
        let response = router
            .clone()
            .oneshot(request(
                "PUT",
                "/bots/commands",
                &bot_token,
                Some(register_body(reserved, json!([]))),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "{reserved:?} already means something to the composer"
        );
    }
}

#[tokio::test]
async fn a_whitespace_prefix_is_rejected() {
    let (store, _guard) = new_store("slimm-botcmds-space-prefix").await;
    let (admin_id, _admin_token) = register(&store, "root").await;
    let (_bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    let response = router
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body("go ", json!([]))),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A description and a usage hint are read by every member in the command
/// menu, so they refuse what a button label and a `/bots/ui` label refuse.
#[tokio::test]
async fn hidden_characters_in_a_description_usage_or_prefix_are_rejected() {
    let (store, _guard) = new_store("slimm-botcmds-hidden").await;
    let (admin_id, _admin_token) = register(&store, "root").await;
    let (_bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    let bodies = [
        register_body(
            "!",
            json!([{ "name": "ping", "description": "safe\u{202E}txt" }]),
        ),
        register_body(
            "!",
            json!([{ "name": "ping", "description": "pong", "usage": "[a\u{200B}b]" }]),
        ),
        register_body("!\u{3164}", json!([])),
    ];
    for body in bodies {
        let response = router
            .clone()
            .oneshot(request(
                "PUT",
                "/bots/commands",
                &bot_token,
                Some(body.clone()),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{body}");
    }
}

#[tokio::test]
async fn a_duplicate_command_name_is_rejected_case_insensitively() {
    let (store, _guard) = new_store("slimm-botcmds-dup").await;
    let (admin_id, _admin_token) = register(&store, "root").await;
    let (_bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    let response = router
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([
                    { "name": "ping", "description": "one" },
                    { "name": "PING", "description": "two" }
                ]),
            )),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn more_than_the_cap_is_rejected_and_the_old_set_survives() {
    let (store, _guard) = new_store("slimm-botcmds-cap").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "keep", "description": "still here" }]),
            )),
        ))
        .await
        .unwrap();

    let too_many: Vec<Value> = (0..51)
        .map(|i| json!({ "name": format!("cmd{i}"), "description": "d" }))
        .collect();
    let response = router
        .clone()
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body("!", json!(too_many))),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let response = router
        .oneshot(request(
            "GET",
            &format!("/bots/{bot_id}/commands"),
            &admin_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        json_body(response).await["commands"],
        json!([{ "name": "keep", "description": "still here" }]),
        "a rejected bulk overwrite must not partially apply"
    );
}

#[tokio::test]
async fn an_invalid_permission_bit_is_rejected() {
    let (store, _guard) = new_store("slimm-botcmds-badbit").await;
    let (admin_id, _admin_token) = register(&store, "root").await;
    let (_bot_id, bot_token) = bot(&store, admin_id, "helper").await;
    let router = app(store);

    // 3 sets two bits at once, never a single permission.
    let response = router
        .oneshot(request(
            "PUT",
            "/bots/commands",
            &bot_token,
            Some(register_body(
                "!",
                json!([{ "name": "ban", "description": "d", "permission": 3 }]),
            )),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// The behavioural half `account_deletion_coverage.rs` does not check
/// itself: that the purge actually happens.
#[tokio::test]
async fn deleting_a_bots_account_purges_its_registration() {
    let (store, _guard) = new_store("slimm-botcmds-account-deleted").await;
    let (admin_id, admin_token) = register(&store, "root").await;
    let (bot_id, bot_token) = bot(&store, admin_id, "helper").await;
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

    store.delete_account(bot_id).await.unwrap();

    let response = router
        .oneshot(request(
            "GET",
            &format!("/bots/{bot_id}/commands"),
            &admin_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        json_body(response).await,
        json!({ "prefix": null, "commands": [] }),
        "a deleted bot's registration must be purged, not merely masked"
    );
}
