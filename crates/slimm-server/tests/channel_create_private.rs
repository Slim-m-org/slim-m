// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels`'s `restricted` flag: closes the window between "channel
//! exists" and "channel is private" that a create-then-restrict two-step
//! leaves open.
//!
//! Three things this covers, none of which the `restricted` field itself
//! (pinned in `channel_restricted.rs`) exercises: the write actually denies
//! `@everyone` and grants the creator, the flag is gated on MANAGE_ROLES in
//! addition to the MANAGE_CHANNELS every create already needs, and the
//! channel row and its overwrites land in one transaction - proven by
//! forcing a failure between the row insert and the overwrite writes and
//! showing the row does not survive either.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{CreateChannelError, Store};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, request_json as request};

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// The deployment's first account: claims bootstrap, so it holds
/// ADMINISTRATOR (MANAGE_CHANNELS and MANAGE_ROLES both resolve true) and an
/// `@everyone` role already exists under it.
async fn register_admin(store: &Store) -> (String, slimm_server::ids::UserId) {
    let account = store
        .create_account("admin", "admin", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (token, account.id)
}

/// A second member with only `extra` on top of whatever `@everyone` grants -
/// never ADMINISTRATOR, so this account's own view of a private channel
/// depends entirely on the overwrites the create actually wrote.
async fn register_member(
    store: &Store,
    username: &str,
    extra: Permissions,
) -> (String, slimm_server::ids::UserId) {
    let user = store.create_user(username, username).await.unwrap();
    if extra != Permissions::NONE {
        let role_id = store
            .create_role(&format!("{username}-role"), extra, false)
            .await
            .unwrap();
        store.assign_role(user.id, role_id).await.unwrap();
    }
    let token = store
        .open_session(user.id, "cli")
        .await
        .unwrap()
        .access_token;
    (token, user.id)
}

async fn channel_names(app: &Router, token: &str) -> Vec<String> {
    let listed = json_body(app.clone().oneshot(get("/channels", token)).await.unwrap()).await;
    listed
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap().to_owned())
        .collect()
}

/// The happy path: `@everyone` is denied VIEW_CHANNEL, the creator is
/// granted it, and an ordinary member with neither ADMINISTRATOR nor any
/// overwrite of their own cannot see the channel at all.
#[tokio::test]
async fn restricted_create_denies_everyone_and_grants_only_the_creator() {
    let (store, _guard) = support::new_store("slimm-channel-create-private-test").await;
    let (admin_token, admin_id) = register_admin(&store).await;
    let (member_token, _member_id) = register_member(&store, "bystander", Permissions::NONE).await;
    let app = app(store.clone());

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            &admin_token,
            json!({ "name": "secret", "restricted": true }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let created = json_body(response).await;
    let channel_id = ChannelId(Uuid::parse_str(created["id"].as_str().unwrap()).unwrap());

    let everyone_id = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap()
        .id;
    let everyone_overwrite = store
        .overwrite_for(channel_id, "role", everyone_id.0)
        .await
        .unwrap()
        .expect("the create wrote an @everyone overwrite");
    assert!(everyone_overwrite.1.contains(Permissions::VIEW_CHANNEL));

    let creator_overwrite = store
        .overwrite_for(channel_id, "member", admin_id.0)
        .await
        .unwrap()
        .expect("the create wrote a member overwrite for the creator");
    assert!(creator_overwrite.0.contains(Permissions::VIEW_CHANNEL));

    assert!(
        !channel_names(&app, &member_token)
            .await
            .contains(&"secret".to_string()),
        "a plain member sees nothing beyond @everyone's own denied view"
    );
    assert!(
        channel_names(&app, &admin_token)
            .await
            .contains(&"secret".to_string()),
        "the creator's own overwrite still shows it to them"
    );
}

/// MANAGE_CHANNELS alone is not enough to ask for `restricted`: it would be a
/// new way to write a permissions overwrite for a holder who could not
/// already do that through `setRoleOverwrite`/`setMemberOverwrite`.
#[tokio::test]
async fn restricted_create_without_manage_roles_is_forbidden() {
    let (store, _guard) = support::new_store("slimm-channel-create-private-test").await;
    register_admin(&store).await;
    let (token, _id) = register_member(&store, "manager", Permissions::MANAGE_CHANNELS).await;
    let app = app(store.clone());

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            &token,
            json!({ "name": "should-not-exist", "restricted": true }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(
        !channel_names(&app, &token)
            .await
            .contains(&"should-not-exist".to_string()),
        "a refused create must not leave a public channel behind either"
    );

    // MANAGE_CHANNELS on its own still creates an ordinary, non-restricted channel.
    let ordinary = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            &token,
            json!({ "name": "ordinary" }),
        ))
        .await
        .unwrap();
    assert_eq!(ordinary.status(), StatusCode::OK);
}

/// The channel row, its seq counters, and its two overwrites all land in one
/// transaction. Forced here by asking for a private channel on a store with
/// no `@everyone` role yet to deny against: the row insert and the seq
/// counter insert both run before that is discovered, so if the create were
/// not atomic, they would survive the refusal. They do not.
#[tokio::test]
async fn a_private_create_that_fails_leaves_no_channel_behind() {
    let (store, _guard) = support::new_store("slimm-channel-create-private-test").await;
    let creator = store.create_user("bob", "bob").await.unwrap();
    let id = ChannelId::generate();

    let err = store
        .create_channel_with_id(id, "secret", "text", None, Some(creator.id), false)
        .await
        .expect_err("no @everyone role exists yet to deny against");
    assert!(matches!(err, CreateChannelError::MissingEveryoneRole));

    assert!(
        store.channel(id).await.unwrap().is_none(),
        "the channel row must not survive a transaction that could not finish writing its overwrites"
    );
}
