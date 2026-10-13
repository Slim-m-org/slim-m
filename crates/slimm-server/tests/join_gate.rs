// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The join gate and raid mode, through the real routes: a new member who has
//! not accepted the rules reads only the rules channel, and a paused Space
//! takes nobody.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, general_channel_id, new_store, register, request};

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(method, uri, token, body))
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

/// The owner, an open Space, a rules channel, and the gate turned on.
async fn gated(prefix: &str) -> (Router, Store, String, String, support::TestDbGuard) {
    let (store, guard) = new_store(prefix).await;
    let app = app(store.clone());
    let (admin, _) = register(&store, "owner").await;
    let (status, _) = call(
        &app,
        "PATCH",
        "/space/settings",
        Some(&admin),
        Some(json!({"join_policy": "open"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, rules) = call(
        &app,
        "POST",
        "/channels",
        Some(&admin),
        Some(json!({"name": "rules"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{rules}");
    let rules_id = rules["id"].as_str().unwrap().to_owned();
    let gate = json!({"enabled": true, "rules": "be kind", "rules_channel_id": rules_id, "joins_paused": false});
    let (status, body) = call(&app, "PUT", "/space/join-gate", Some(&admin), Some(gate)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    (app, store, admin, rules_id, guard)
}

async fn join(app: &Router, username: &str) -> (StatusCode, Value) {
    let body = json!({"username": username, "display_name": username, "password": "hunter2hunter2", "device_name": "cli"});
    call(app, "POST", "/auth/register", None, Some(body)).await
}

async fn joined_token(app: &Router, username: &str) -> String {
    let (status, body) = join(app, username).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["access_token"].as_str().unwrap().to_owned()
}

async fn visible_channels(app: &Router, token: &str) -> Vec<String> {
    let (status, body) = call(app, "GET", "/channels", Some(token), None).await;
    assert_eq!(status, StatusCode::OK);
    body.as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect()
}

async fn post(app: &Router, token: &str, channel: &str) -> StatusCode {
    let body = json!({"id": uuid::Uuid::now_v7().to_string(), "content": "hello"});
    call(
        app,
        "POST",
        &format!("/channels/{channel}/messages"),
        Some(token),
        Some(body),
    )
    .await
    .0
}

#[tokio::test]
async fn a_pending_member_sees_only_the_rules_channel_and_cannot_post() {
    let (app, store, _admin, rules, _guard) = gated("slimm-join-gate-pending").await;
    let general = general_channel_id(&store).await;
    let bob = joined_token(&app, "bob").await;

    assert_eq!(visible_channels(&app, &bob).await, vec![rules.clone()]);
    let (status, _) = call(
        &app,
        "GET",
        &format!("/channels/{rules}/messages"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "the rules channel stays readable");
    assert_eq!(post(&app, &bob, &rules).await, StatusCode::FORBIDDEN);
    assert_eq!(post(&app, &bob, &general).await, StatusCode::FORBIDDEN);

    let (status, body) = call(&app, "GET", "/space/rules", Some(&bob), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["pending"], json!(true));
    assert_eq!(body["rules"], json!("be kind"));
}

#[tokio::test]
async fn accepting_the_rules_lets_the_member_in() {
    let (app, store, _admin, _rules, _guard) = gated("slimm-join-gate-accept").await;
    let general = general_channel_id(&store).await;
    let bob = joined_token(&app, "bob").await;

    let (status, _) = call(&app, "POST", "/space/rules/accept", Some(&bob), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(visible_channels(&app, &bob).await.contains(&general));
    assert_eq!(post(&app, &bob, &general).await, StatusCode::OK);
    let (_, body) = call(&app, "GET", "/space/rules", Some(&bob), None).await;
    assert_eq!(body["pending"], json!(false));

    let (status, _) = call(&app, "POST", "/space/rules/accept", Some(&bob), None).await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "accepting again is harmless"
    );
}

#[tokio::test]
async fn a_pending_member_cannot_open_a_dm() {
    let (app, _store, _admin, _rules, _guard) = gated("slimm-join-gate-dm").await;
    let bob = joined_token(&app, "bob").await;
    let (_, me) = call(&app, "GET", "/me", Some(&bob), None).await;
    let carol = joined_token(&app, "carol").await;
    let (_, carol_me) = call(&app, "GET", "/me", Some(&carol), None).await;
    let carol_id = carol_me["id"].as_str().unwrap();
    assert!(me["id"].is_string());

    let (status, _) = call(&app, "POST", &format!("/dms/{carol_id}"), Some(&bob), None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn the_owner_and_members_from_before_the_gate_are_not_gated() {
    let (store, _guard) = new_store("slimm-join-gate-existing").await;
    let app = app(store.clone());
    let (admin, _) = register(&store, "owner").await;
    call(
        &app,
        "PATCH",
        "/space/settings",
        Some(&admin),
        Some(json!({"join_policy": "open"})),
    )
    .await;
    let early = joined_token(&app, "early").await;
    let gate = json!({"enabled": true, "rules": "be kind", "rules_channel_id": null, "joins_paused": false});
    assert_eq!(
        call(&app, "PUT", "/space/join-gate", Some(&admin), Some(gate))
            .await
            .0,
        StatusCode::OK
    );

    let general = general_channel_id(&store).await;
    assert_eq!(post(&app, &admin, &general).await, StatusCode::OK);
    assert_eq!(post(&app, &early, &general).await, StatusCode::OK);
    let late = joined_token(&app, "late").await;
    assert!(
        visible_channels(&app, &late).await.is_empty(),
        "no rules channel means nothing to see yet"
    );
}

#[tokio::test]
async fn turning_the_gate_off_lets_everyone_waiting_in() {
    let (app, store, admin, _rules, _guard) = gated("slimm-join-gate-off").await;
    let general = general_channel_id(&store).await;
    let bob = joined_token(&app, "bob").await;
    let off = json!({"enabled": false, "rules": "be kind", "rules_channel_id": null, "joins_paused": false});
    assert_eq!(
        call(&app, "PUT", "/space/join-gate", Some(&admin), Some(off))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(post(&app, &bob, &general).await, StatusCode::OK);
}

#[tokio::test]
async fn a_paused_space_refuses_every_new_member() {
    let (app, _store, admin, rules, _guard) = gated("slimm-join-gate-paused").await;
    let paused = json!({"enabled": true, "rules": "be kind", "rules_channel_id": rules, "joins_paused": true});
    assert_eq!(
        call(&app, "PUT", "/space/join-gate", Some(&admin), Some(paused))
            .await
            .0,
        StatusCode::OK
    );

    let (status, body) = join(&app, "raider").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        body["error"],
        json!("this space is not taking new members right now")
    );
}

#[tokio::test]
async fn only_a_manager_changes_the_gate_and_bad_settings_change_nothing() {
    let (app, store, admin, _rules, _guard) = gated("slimm-join-gate-validate").await;
    let bob = joined_token(&app, "bob").await;
    call(&app, "POST", "/space/rules/accept", Some(&bob), None).await;
    let any =
        json!({"enabled": false, "rules": "", "rules_channel_id": null, "joins_paused": false});
    assert_eq!(
        call(&app, "PUT", "/space/join-gate", Some(&bob), Some(any))
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        call(&app, "GET", "/space/join-gate", Some(&bob), None)
            .await
            .0,
        StatusCode::FORBIDDEN
    );

    let before = store.join_gate().await.unwrap();
    for bad in [
        json!({"enabled": true, "rules": "  ", "rules_channel_id": null, "joins_paused": false}),
        json!({"enabled": true, "rules": "x".repeat(4001), "rules_channel_id": null, "joins_paused": false}),
        json!({"enabled": true, "rules": "be\u{200B}kind", "rules_channel_id": null, "joins_paused": false}),
        json!({"enabled": true, "rules": "ok", "rules_channel_id": uuid::Uuid::now_v7().to_string(), "joins_paused": false}),
    ] {
        let (status, body) = call(&app, "PUT", "/space/join-gate", Some(&admin), Some(bad)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    }
    assert_eq!(store.join_gate().await.unwrap(), before);
}

#[tokio::test]
async fn push_fan_out_and_batch_checks_apply_the_gate_too() {
    use slimm_server::ids::{ChannelId, UserId};
    use slimm_server::permissions::Permissions;

    let (app, store, _admin, rules, _guard) = gated("slimm-join-gate-batch").await;
    let general: ChannelId = ChannelId(general_channel_id(&store).await.parse().unwrap());
    let rules = ChannelId(rules.parse().unwrap());
    let bob = joined_token(&app, "bob").await;
    let (_, me) = call(&app, "GET", "/me", Some(&bob), None).await;
    let bob_id = UserId(me["id"].as_str().unwrap().parse().unwrap());

    assert!(
        store
            .viewers_among(general, &[bob_id])
            .await
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store.viewers_among(rules, &[bob_id]).await.unwrap(),
        vec![bob_id]
    );
    let batch = store
        .permissions_in_channels(bob_id, &[general, rules])
        .await
        .unwrap();
    assert_eq!(batch[&general], Permissions::NONE);
    assert_eq!(batch[&rules], Permissions::VIEW_CHANNEL);

    store.accept_rules(bob_id).await.unwrap();
    assert_eq!(
        store.viewers_among(general, &[bob_id]).await.unwrap(),
        vec![bob_id]
    );
}
