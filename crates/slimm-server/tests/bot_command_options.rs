// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Command options with fixed choices on `PUT /bots/commands`, read back by
//! `GET /bots/{botId}/commands` and the composer's discovery list.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{
    app, json_body_or_null as json_body, register_id_token as register, request_authed as request,
};

struct World {
    router: Router,
    admin_token: String,
    bot_id: String,
    bot_token: String,
    channel: String,
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let (admin_id, admin_token) = register(&store, "root").await;
    let new_bot = store
        .create_bot("deals", "Deals", Permissions::NONE, admin_id)
        .await
        .unwrap();
    let channel = store.list_channels().await.unwrap().remove(0).id;
    World {
        router: app(store),
        admin_token,
        bot_id: new_bot.bot.user_id.to_string(),
        bot_token: new_bot.token,
        channel: channel.to_string(),
        _guard: guard,
    }
}

async fn put_commands(w: &World, commands: Value) -> StatusCode {
    let body = json!({ "prefix": "!", "commands": commands });
    w.router
        .clone()
        .oneshot(request("PUT", "/bots/commands", &w.bot_token, Some(body)))
        .await
        .unwrap()
        .status()
}

async fn get_json(w: &World, path: &str) -> Value {
    let response = w
        .router
        .clone()
        .oneshot(request("GET", path, &w.admin_token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

fn command(options: Value) -> Value {
    json!([{ "name": "sources", "description": "pick a store", "options": options }])
}

#[tokio::test]
async fn choices_round_trip_through_both_read_routes() {
    let w = world("slimm-botopts-roundtrip").await;
    let options = json!([{ "name": "source", "required": true, "choices": ["steam", "gog"] }]);
    assert_eq!(
        put_commands(&w, command(options.clone())).await,
        StatusCode::NO_CONTENT
    );

    let own = get_json(&w, &format!("/bots/{}/commands", w.bot_id)).await;
    assert_eq!(own["commands"][0]["options"], options);
    let listed = get_json(&w, &format!("/channels/{}/bot-commands", w.channel)).await;
    assert_eq!(listed[0]["options"], options);
}

#[tokio::test]
async fn a_command_without_options_omits_the_field() {
    let w = world("slimm-botopts-none").await;
    let plain = json!([{ "name": "ping", "description": "pong" }]);
    assert_eq!(put_commands(&w, plain).await, StatusCode::NO_CONTENT);
    let listed = get_json(&w, &format!("/channels/{}/bot-commands", w.channel)).await;
    assert!(listed[0].get("options").is_none());
}

#[tokio::test]
async fn invalid_options_are_refused_and_keep_the_old_registration() {
    let w = world("slimm-botopts-invalid").await;
    let good = json!([{ "name": "source", "choices": ["steam"] }]);
    assert_eq!(
        put_commands(&w, command(good)).await,
        StatusCode::NO_CONTENT
    );

    let too_many_choices: Vec<String> = (0..26).map(|i| format!("c{i}")).collect();
    let too_many_options: Vec<Value> = (0..6).map(|i| json!({ "name": format!("o{i}") })).collect();
    let bad = [
        json!([{ "name": "a b" }]),
        json!([{ "name": "" }]),
        json!([{ "name": "x", "choices": ["two words"] }]),
        json!([{ "name": "x", "choices": [""] }]),
        json!([{ "name": "x", "choices": ["a", "A"] }]),
        json!([{ "name": "x", "choices": too_many_choices }]),
        json!([{ "name": "x" }, { "name": "X" }]),
        json!(too_many_options),
        json!([{ "name": "x", "choices": ["a".repeat(101)] }]),
    ];
    for options in bad {
        assert_eq!(
            put_commands(&w, command(options.clone())).await,
            StatusCode::BAD_REQUEST,
            "{options}"
        );
    }
    let own = get_json(&w, &format!("/bots/{}/commands", w.bot_id)).await;
    assert_eq!(
        own["commands"][0]["options"][0]["choices"],
        json!(["steam"])
    );
}
