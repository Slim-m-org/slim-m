// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An admin changing the prefix a bot answers to after it was added.
//! See docs/decisions/0069-bot-prefix-assignment.md.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};

mod support;

use support::app::call_as as call;
use support::overwrite_harness::{app, new_store, register};

async fn make_bot(router: &Router, root: &str, name: &str, prefix: &str) -> (String, String) {
    let body = json!({ "username": name, "prefix": prefix });
    let (status, created) = call(router, "POST", "/bots", root, Some(body)).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    (
        created["bot"]["user_id"].as_str().unwrap().to_owned(),
        created["token"].as_str().unwrap().to_owned(),
    )
}

async fn register_commands(router: &Router, token: &str, prefix: &str, names: &[&str]) {
    let commands: Vec<Value> = names
        .iter()
        .map(|n| json!({ "name": n, "description": format!("the {n} command") }))
        .collect();
    let body = json!({ "prefix": prefix, "commands": commands });
    let (status, response) = call(router, "PUT", "/bots/commands", token, Some(body)).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{response}");
}

async fn set_prefix(router: &Router, token: &str, bot: &str, prefix: &str) -> (StatusCode, Value) {
    let path = format!("/bots/{bot}/prefix");
    call(
        router,
        "PATCH",
        &path,
        token,
        Some(json!({ "prefix": prefix })),
    )
    .await
}

#[tokio::test]
async fn an_admin_moves_a_bot_and_its_commands_to_a_free_prefix() {
    let (store, _guard) = new_store("slimm-botprefix-change").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);
    let (bot_id, token) = make_bot(&router, &root, "watcher", "!").await;
    register_commands(&router, &token, "!", &["watch"]).await;

    let (status, moved) = set_prefix(&router, &root, &bot_id, "~").await;
    assert_eq!(status, StatusCode::OK, "{moved}");
    assert_eq!(moved["prefix"], "~");

    let (_, me) = call(&router, "GET", "/me", &token, None).await;
    assert_eq!(me["bot_prefix"], "~");
    let (_, held) = call(
        &router,
        "GET",
        &format!("/bots/{bot_id}/commands"),
        &root,
        None,
    )
    .await;
    assert_eq!(held["prefix"], "~");
    assert_eq!(held["commands"].as_array().unwrap().len(), 1);
    let (_, taken) = call(&router, "GET", "/bots/suggested-prefix", &root, None).await;
    assert_eq!(taken["prefix"], "!", "the old prefix is free again");
}

#[tokio::test]
async fn a_bot_that_never_registered_can_still_be_moved() {
    let (store, _guard) = new_store("slimm-botprefix-change-bare").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);
    let (bot_id, token) = make_bot(&router, &root, "quiet", "!").await;

    let (status, body) = set_prefix(&router, &root, &bot_id, "?").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    register_commands(&router, &token, "?", &["ping"]).await;
}

#[tokio::test]
async fn a_move_onto_a_prefix_where_a_command_name_is_taken_is_refused_and_names_it() {
    let (store, _guard) = new_store("slimm-botprefix-change-clash").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);
    let (_, jellyfin) = make_bot(&router, &root, "jellyfin", "!").await;
    register_commands(&router, &jellyfin, "!", &["watch", "queue"]).await;
    let (deals_id, deals) = make_bot(&router, &root, "deals", "?").await;
    register_commands(&router, &deals, "?", &["Watch", "pricewatch"]).await;

    let (status, body) = set_prefix(&router, &root, &deals_id, "!").await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert!(body.to_string().contains("Watch"), "{body}");
    let (_, still) = call(
        &router,
        "GET",
        &format!("/bots/{deals_id}/commands"),
        &root,
        None,
    )
    .await;
    assert_eq!(
        still["prefix"], "?",
        "a refused move leaves the registration alone"
    );
    let (_, me) = call(&router, "GET", "/me", &deals, None).await;
    assert_eq!(me["bot_prefix"], "?");
}

#[tokio::test]
async fn a_shared_prefix_is_fine_while_the_names_differ() {
    let (store, _guard) = new_store("slimm-botprefix-change-share").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);
    let (_, jellyfin) = make_bot(&router, &root, "jellyfin", "!").await;
    register_commands(&router, &jellyfin, "!", &["watch"]).await;
    let (deals_id, deals) = make_bot(&router, &root, "deals", "?").await;
    register_commands(&router, &deals, "?", &["pricewatch"]).await;

    let (status, _) = set_prefix(&router, &root, &deals_id, "!").await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_revoked_bots_commands_do_not_block_a_move() {
    let (store, _guard) = new_store("slimm-botprefix-change-revoked").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);
    let (old_id, old) = make_bot(&router, &root, "old", "!").await;
    register_commands(&router, &old, "!", &["watch"]).await;
    call(
        &router,
        "POST",
        &format!("/bots/{old_id}/revoke"),
        &root,
        None,
    )
    .await;
    let (new_id, fresh) = make_bot(&router, &root, "fresh", "?").await;
    register_commands(&router, &fresh, "?", &["watch"]).await;

    let (status, _) = set_prefix(&router, &root, &new_id, "!").await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn the_old_prefix_is_refused_after_the_move() {
    let (store, _guard) = new_store("slimm-botprefix-change-old").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);
    let (bot_id, token) = make_bot(&router, &root, "one", "!").await;
    set_prefix(&router, &root, &bot_id, "~").await;

    let body = json!({ "prefix": "!", "commands": [{ "name": "ping", "description": "pong" }] });
    let (status, response) = call(&router, "PUT", "/bots/commands", &token, Some(body)).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert!(
        response.to_string().contains("assigned the prefix ~"),
        "{response}"
    );
}

#[tokio::test]
async fn a_bad_prefix_a_missing_bot_or_a_member_without_manage_server_is_refused() {
    let (store, _guard) = new_store("slimm-botprefix-change-refused").await;
    let (root, _) = register(&store, "root").await;
    let (member, _) = register(&store, "member").await;
    let router = app(store);
    let (bot_id, token) = make_bot(&router, &root, "one", "!").await;

    for bad in ["/", "@", ":", "a b", "", "seventeen-chars-xx"] {
        let (status, _) = set_prefix(&router, &root, &bot_id, bad).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "prefix {bad:?}");
    }
    let unknown = "0192a000-0000-7000-8000-000000000000";
    assert_eq!(
        set_prefix(&router, &root, unknown, "~").await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        set_prefix(&router, &member, &bot_id, "~").await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        set_prefix(&router, &token, &bot_id, "~").await.0,
        StatusCode::FORBIDDEN
    );
    let (_, bots) = call(&router, "GET", "/bots", &root, None).await;
    assert_eq!(bots[0]["prefix"], "!");
}
