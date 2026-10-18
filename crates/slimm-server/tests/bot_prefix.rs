// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bot prefix assignment and collision refusal, plus the read-only member
//! permissions route a bot uses. See docs/decisions/0069-bot-prefix-assignment.md.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, general_channel_id, new_store, register, request};

async fn call(
    router: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let response = router
        .clone()
        .oneshot(request(method, uri, Some(token), body))
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

async fn make_bot(
    router: &Router,
    root: &str,
    name: &str,
    prefix: Option<&str>,
) -> (String, String, Value) {
    let mut body = json!({ "username": name });
    if let Some(prefix) = prefix {
        body["prefix"] = json!(prefix);
    }
    let (status, created) = call(router, "POST", "/bots", root, Some(body)).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    (
        created["bot"]["user_id"].as_str().unwrap().to_owned(),
        created["token"].as_str().unwrap().to_owned(),
        created["bot"].clone(),
    )
}

fn register_body(prefix: &str, names: &[&str]) -> Value {
    let commands: Vec<Value> = names
        .iter()
        .map(|n| json!({ "name": n, "description": format!("the {n} command") }))
        .collect();
    json!({ "prefix": prefix, "commands": commands })
}

async fn registered_names(router: &Router, root: &str, bot_id: &str) -> Vec<String> {
    let (_, reg) = call(
        router,
        "GET",
        &format!("/bots/{bot_id}/commands"),
        root,
        None,
    )
    .await;
    reg["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn the_suggested_prefix_skips_one_a_live_bot_holds() {
    let (store, _guard) = new_store("slimm-botprefix-suggest").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);

    let (status, first) = call(&router, "GET", "/bots/suggested-prefix", &root, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(first["prefix"], "!");

    make_bot(&router, &root, "one", None).await;
    let (_, second) = call(&router, "GET", "/bots/suggested-prefix", &root, None).await;
    assert_eq!(second["prefix"], "?");
}

#[tokio::test]
async fn a_revoked_bots_prefix_is_free_again() {
    let (store, _guard) = new_store("slimm-botprefix-revoked").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);

    let (bot_id, _, _) = make_bot(&router, &root, "one", None).await;
    let (status, _) = call(
        &router,
        "POST",
        &format!("/bots/{bot_id}/revoke"),
        &root,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, suggestion) = call(&router, "GET", "/bots/suggested-prefix", &root, None).await;
    assert_eq!(suggestion["prefix"], "!");
}

#[tokio::test]
async fn a_new_bot_is_assigned_a_prefix_and_reads_it_from_me() {
    let (store, _guard) = new_store("slimm-botprefix-assign").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);

    let (_, token, bot) = make_bot(&router, &root, "picked", Some("~")).await;
    assert_eq!(bot["prefix"], "~");
    let (_, me) = call(&router, "GET", "/me", &token, None).await;
    assert_eq!(me["bot_prefix"], "~");

    let (_, _, defaulted) = make_bot(&router, &root, "defaulted", None).await;
    assert_eq!(defaulted["prefix"], "!");

    let (_, listed) = call(&router, "GET", "/bots", &root, None).await;
    assert!(
        listed
            .as_array()
            .unwrap()
            .iter()
            .any(|b| b["prefix"] == "~")
    );
    let (_, me_root) = call(&router, "GET", "/me", &root, None).await;
    assert!(me_root.get("bot_prefix").is_none());
}

#[tokio::test]
async fn a_reserved_or_blank_prefix_is_refused_at_creation() {
    let (store, _guard) = new_store("slimm-botprefix-invalid").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);

    for bad in ["/", "@", ":", "a b", ""] {
        let (status, _) = call(
            &router,
            "POST",
            "/bots",
            &root,
            Some(json!({ "username": "x", "prefix": bad })),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "prefix {bad:?}");
    }
}

#[tokio::test]
async fn a_bot_cannot_register_under_a_prefix_it_was_not_assigned() {
    let (store, _guard) = new_store("slimm-botprefix-mismatch").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);

    let (_, token, _) = make_bot(&router, &root, "one", Some("!")).await;
    let (status, body) = call(
        &router,
        "PUT",
        "/bots/commands",
        &token,
        Some(register_body("?", &["ping"])),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert!(body.to_string().contains("assigned the prefix !"), "{body}");
    let (status, _) = call(
        &router,
        "PUT",
        "/bots/commands",
        &token,
        Some(register_body("!", &["ping"])),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn two_bots_share_a_prefix_only_while_their_command_names_differ() {
    let (store, _guard) = new_store("slimm-botprefix-collision").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);

    let (_, jellyfin, _) = make_bot(&router, &root, "jellyfin", Some("!")).await;
    let (deals_id, deals, _) = make_bot(&router, &root, "deals", Some("!")).await;
    let (status, _) = call(
        &router,
        "PUT",
        "/bots/commands",
        &jellyfin,
        Some(register_body("!", &["watch", "queue"])),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (status, _) = call(
        &router,
        "PUT",
        "/bots/commands",
        &deals,
        Some(register_body("!", &["Watch", "pricewatch"])),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, held) = call(
        &router,
        "GET",
        &format!("/bots/{deals_id}/commands"),
        &root,
        None,
    )
    .await;
    let names: Vec<&str> = held["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["pricewatch"], "{held}");

    let (status, _) = call(
        &router,
        "PUT",
        "/bots/commands",
        &deals,
        Some(register_body("!", &["pricewatch"])),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_revoked_bots_commands_stop_blocking_others() {
    let (store, _guard) = new_store("slimm-botprefix-freed").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);

    let (old_id, old, _) = make_bot(&router, &root, "old", Some("!")).await;
    let (new_id, new, _) = make_bot(&router, &root, "new", Some("!")).await;
    call(
        &router,
        "PUT",
        "/bots/commands",
        &old,
        Some(register_body("!", &["watch"])),
    )
    .await;
    let (status, _) = call(
        &router,
        "PUT",
        "/bots/commands",
        &new,
        Some(register_body("!", &["watch"])),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(registered_names(&router, &root, &new_id).await.is_empty());

    call(
        &router,
        "POST",
        &format!("/bots/{old_id}/revoke"),
        &root,
        None,
    )
    .await;
    let (status, _) = call(
        &router,
        "PUT",
        "/bots/commands",
        &new,
        Some(register_body("!", &["watch"])),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(registered_names(&router, &root, &new_id).await, ["watch"]);
}

#[tokio::test]
async fn a_bot_keeps_a_name_it_already_held_when_another_bot_took_it_too() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-botprefix-existing").await;
    let (root, _) = register(&store, "root").await;
    let router = app(store);

    let (jelly_id, jelly, _) = make_bot(&router, &root, "jellyfin", Some("!")).await;
    let (pelican_id, pelican, _) = make_bot(&router, &root, "pelican", Some("!")).await;
    for id in [&jelly_id, &pelican_id] {
        let id = uuid::Uuid::parse_str(id).unwrap();
        sqlx::query("INSERT INTO bot_command_registrations (bot_user_id, prefix, updated_at) VALUES (?, '!', 1)")
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO bot_commands (bot_user_id, name, description, position) VALUES (?, 'stop', 'stop it', 0)")
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
    }
    for token in [&jelly, &pelican] {
        let (status, _) = call(
            &router,
            "PUT",
            "/bots/commands",
            token,
            Some(register_body("!", &["stop"])),
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }
    assert_eq!(registered_names(&router, &root, &jelly_id).await, ["stop"]);
    assert_eq!(
        registered_names(&router, &root, &pelican_id).await,
        ["stop"]
    );
}

#[tokio::test]
async fn the_composer_list_never_shows_two_bots_answering_one_trigger() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-botprefix-dedupe").await;
    let (root, _) = register(&store, "root").await;
    let general = general_channel_id(&store).await;
    let router = app(store);

    let (first_id, first, _) = make_bot(&router, &root, "first", Some("!")).await;
    let (second_id, _, _) = make_bot(&router, &root, "second", Some("!")).await;
    call(
        &router,
        "PUT",
        "/bots/commands",
        &first,
        Some(register_body("!", &["watch"])),
    )
    .await;
    // Registered before refusal existed: written straight to the table.
    sqlx::query("INSERT INTO bot_command_registrations (bot_user_id, prefix, updated_at) VALUES (?, '!', 9999999999999)")
        .bind(uuid::Uuid::parse_str(&second_id).unwrap())
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO bot_commands (bot_user_id, name, description, position) VALUES (?, 'watch', 'a price alert', 0)")
        .bind(uuid::Uuid::parse_str(&second_id).unwrap())
        .execute(&pool)
        .await
        .unwrap();

    let (_, rows) = call(
        &router,
        "GET",
        &format!("/channels/{general}/bot-commands"),
        &root,
        None,
    )
    .await;
    let watches: Vec<&Value> = rows
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["name"] == "watch")
        .collect();
    assert_eq!(watches.len(), 1, "{rows}");
    assert_eq!(watches[0]["bot_user_id"], first_id);
}

#[tokio::test]
async fn a_bot_without_manage_roles_reads_a_members_permissions() {
    let (store, _guard) = new_store("slimm-botprefix-perms").await;
    let (root, root_id) = register(&store, "root").await;
    let (alice, alice_id) = register(&store, "alice").await;
    let router = app(store);

    let (_, bot, _) = make_bot(&router, &root, "reader", None).await;
    let (status, roles) = call(&router, "GET", "/roles", &bot, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{roles}");

    let (status, body) = call(
        &router,
        "GET",
        &format!("/members/{root_id}/permissions"),
        &bot,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, me) = call(&router, "GET", "/me", &root, None).await;
    assert_eq!(body["permissions"], me["permissions"]);
    assert_eq!(body["user_id"], root_id);

    let (_, alice_me) = call(&router, "GET", "/me", &alice, None).await;
    let (_, alice_bits) = call(
        &router,
        "GET",
        &format!("/members/{alice_id}/permissions"),
        &bot,
        None,
    )
    .await;
    assert_eq!(alice_bits["permissions"], alice_me["permissions"]);

    let (status, _) = call(
        &router,
        "GET",
        &format!("/members/{alice_id}/permissions"),
        &alice,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        &router,
        "GET",
        "/members/not-a-uuid/permissions",
        &bot,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = call(
        &router,
        "GET",
        &format!("/members/{}/permissions", uuid::Uuid::now_v7()),
        &bot,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
