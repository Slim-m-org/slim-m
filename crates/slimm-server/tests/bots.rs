// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bot accounts: who may make one, what its token does, and what stops it.
//!
//! The cases worth holding are the ones where a bot could quietly become more
//! than a member. Decision 0028's whole claim is that a bot is a user-shaped
//! principal, so most of its behaviour is already covered by the tests for the
//! surfaces it reuses; what is *not* covered anywhere else is the provisioning
//! gate, the prefix routing, revocation taking effect immediately, and the rule
//! that a bot cannot provision another bot.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::store::{BOT_TOKEN_PREFIX, Store};
use tower::ServiceExt;

mod support;

use support::app::{app, json_body_or_null as json_body, request_authed as request};

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

/// An administrator with a session, and the deployment claimed by them.
async fn admin(store: &Store, username: &str) -> (UserId, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (account.id, token)
}

/// Creates a bot through HTTP and hands back its id and token.
async fn create_bot(app: &Router, token: &str, username: &str) -> (String, String) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            token,
            Some(json!({ "username": username })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = json_body(response).await;
    (
        body["bot"]["user_id"].as_str().unwrap().to_owned(),
        body["token"].as_str().unwrap().to_owned(),
    )
}

#[tokio::test]
async fn a_bot_token_authenticates_as_the_bot_and_nobody_else() {
    let (store, _guard) = new_store("slimm-bots-auth").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());

    let (bot_id, bot_token) = create_bot(&app, &root, "helper").await;
    assert!(
        bot_token.starts_with(BOT_TOKEN_PREFIX),
        "the prefix is what routes a presented credential to the right table"
    );

    let response = app
        .clone()
        .oneshot(request("GET", "/me", &bot_token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let me = json_body(response).await;
    assert_eq!(
        me["id"].as_str().unwrap(),
        bot_id,
        "the token resolves to the bot's own identity, never the creator's"
    );
}

#[tokio::test]
async fn the_token_is_only_ever_legible_once() {
    let (store, _guard) = new_store("slimm-bots-once").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (_bot_id, bot_token) = create_bot(&app, &root, "helper").await;

    let listing = json_body(
        app.clone()
            .oneshot(request("GET", "/bots", &root, None))
            .await
            .unwrap(),
    )
    .await;

    let serialized = listing.to_string();
    assert!(
        !serialized.contains(&bot_token),
        "a listing that carried the token would make a stolen read a stolen bot"
    );
    assert!(
        !serialized.contains("token\":"),
        "no token field at all on the listing shape"
    );
}

#[tokio::test]
async fn revoking_stops_the_bot_on_its_very_next_request() {
    let (store, _guard) = new_store("slimm-bots-revoke").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, bot_token) = create_bot(&app, &root, "helper").await;

    assert_eq!(
        app.clone()
            .oneshot(request("GET", "/me", &bot_token, None))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );

    let revoked = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/revoke"),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::NO_CONTENT);

    assert_eq!(
        app.clone()
            .oneshot(request("GET", "/me", &bot_token, None))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED,
        "not at expiry, not on the next sweep - the next request"
    );
}

#[tokio::test]
async fn a_revoked_bot_is_still_listed_with_no_live_token() {
    let (store, _guard) = new_store("slimm-bots-listing").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _bot_token) = create_bot(&app, &root, "helper").await;
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/revoke"),
            &root,
            None,
        ))
        .await
        .unwrap();

    let listing = json_body(
        app.clone()
            .oneshot(request("GET", "/bots", &root, None))
            .await
            .unwrap(),
    )
    .await;

    let bots = listing.as_array().unwrap();
    assert_eq!(bots.len(), 1, "the account stays, so its authorship stays");
    assert!(
        bots[0]["token_name"].is_null(),
        "an operator has to be able to see that it can no longer act"
    );
}

/// The limit that stops one compromised credential outliving the response to
/// it: a bot holding MANAGE_SERVER still cannot mint a second one.
#[tokio::test]
async fn a_bot_cannot_provision_a_bot_even_holding_manage_server() {
    let (store, _guard) = new_store("slimm-bots-no-forking").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, bot_token) = create_bot(&app, &root, "helper").await;

    // Everything granted, so the refusal cannot read as a missing permission.
    let bot = UserId(bot_id.parse().unwrap());
    store
        .bootstrap_deployment(bot)
        .await
        .expect("granting the bot administrator");

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            &bot_token,
            Some(json!({ "username": "second" })),
        ))
        .await
        .unwrap();

    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "provisioning is a human act"
    );
    let listing = json_body(
        app.clone()
            .oneshot(request("GET", "/bots", &root, None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(listing.as_array().unwrap().len(), 1, "no second bot exists");
}

#[tokio::test]
async fn an_ordinary_member_cannot_provision_or_list_bots() {
    let (store, _guard) = new_store("slimm-bots-member").await;
    let (_admin_id, _root) = admin(&store, "root").await;
    let member = store.create_user("mallory", "Mallory").await.unwrap();
    let token = store
        .open_session(member.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let app = app(store.clone());

    for (method, uri, body) in [
        ("POST", "/bots", Some(json!({ "username": "sneaky" }))),
        ("GET", "/bots", None),
    ] {
        let response = app
            .clone()
            .oneshot(request(method, uri, &token, body))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::FORBIDDEN,
            "{method} {uri} needs MANAGE_SERVER"
        );
    }
}

#[tokio::test]
async fn a_bot_username_follows_the_same_rule_a_person_s_does() {
    let (store, _guard) = new_store("slimm-bots-names").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());

    for bad in ["", "   ", "has space", "at@sign", &"x".repeat(33)] {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                "/bots",
                &root,
                Some(json!({ "username": bad })),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "{bad:?} is not a username a person could have either"
        );
    }
}

#[tokio::test]
async fn two_bots_cannot_share_a_username() {
    let (store, _guard) = new_store("slimm-bots-unique").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    create_bot(&app, &root, "helper").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            &root,
            Some(json!({ "username": "helper" })),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::CONFLICT);
}

/// A bot arrives with no roles, so it holds exactly what `@everyone` holds.
/// Nothing about being a bot adds a permission, which is the claim that lets
/// the rest of the authorization surface go untested here.
#[tokio::test]
async fn a_new_bot_holds_no_more_than_everyone_does() {
    let (store, _guard) = new_store("slimm-bots-default-deny").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, bot_token) = create_bot(&app, &root, "helper").await;

    let bot = UserId(bot_id.parse().unwrap());
    let everyone = store.base_permissions(bot).await.unwrap();
    let plain = store.create_user("dana", "Dana").await.unwrap();
    assert_eq!(
        everyone,
        store.base_permissions(plain.id).await.unwrap(),
        "a bot's starting permissions are a member's starting permissions"
    );

    // And it cannot reach an operator surface with them.
    assert_eq!(
        app.clone()
            .oneshot(request("GET", "/bots", &bot_token, None))
            .await
            .unwrap()
            .status(),
        StatusCode::FORBIDDEN
    );
}

/// The badge's whole job is that a reader can tell without inspecting
/// anything, which means the flag has to reach the wire on the surfaces that
/// draw a name: a profile and the member list.
#[tokio::test]
async fn a_bot_is_marked_as_one_wherever_a_name_is_drawn() {
    let (store, _guard) = new_store("slimm-bots-badge").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _bot_token) = create_bot(&app, &root, "helper").await;

    let profile = json_body(
        app.clone()
            .oneshot(request("GET", &format!("/users/{bot_id}"), &root, None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(profile["is_bot"], true, "a bot's own profile says so");

    let members = json_body(
        app.clone()
            .oneshot(request("GET", "/members", &root, None))
            .await
            .unwrap(),
    )
    .await;
    let members = members.as_array().unwrap();
    let bot = members
        .iter()
        .find(|m| m["id"] == bot_id)
        .expect("a bot is a member like anyone else");
    assert_eq!(bot["is_bot"], true);
    assert!(
        members
            .iter()
            .any(|m| m["id"] != bot_id && m["is_bot"] == false),
        "and a person in the same list is not marked as one"
    );
}
