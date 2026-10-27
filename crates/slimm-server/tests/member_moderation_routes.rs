// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The authorization on the moderation routes, which is the whole of what
//! stands between KICK_MEMBERS and a moderator silencing every administrator
//! on the deployment one at a time.
//!
//! slim-m has no role hierarchy, so the rule doing that job is permission
//! containment: you may only moderate somebody whose granted permissions
//! yours already contain. These tests are what keeps that true, since nothing
//! about the code shape would break if it were dropped.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

use support::app::{app, request_authed as request};

/// The admin who claims the deployment, plus a plain member and a moderator
/// holding exactly the two moderation bits and nothing else.
async fn people(store: &Store) -> (String, String, String, String, String) {
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let admin_token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;

    let mod_role = store
        .create_role(
            "mod",
            Permissions::KICK_MEMBERS.union(Permissions::BAN_MEMBERS),
            false,
        )
        .await
        .unwrap();
    let moderator = store
        .create_account("mod", "Mod", "not-a-real-hash")
        .await
        .unwrap();
    store.assign_role(moderator.id, mod_role).await.unwrap();
    let mod_token = store
        .open_session(moderator.id, "cli")
        .await
        .unwrap()
        .access_token;

    let member = store
        .create_account("nia", "Nia", "not-a-real-hash")
        .await
        .unwrap();

    (
        admin_token,
        admin.id.to_string(),
        mod_token,
        moderator.id.to_string(),
        member.id.to_string(),
    )
}

/// Without this a moderator with KICK_MEMBERS can silence every
/// administrator, one at a time, and there is nothing else in the product
/// that would stop them.
#[tokio::test]
async fn a_moderator_cannot_reach_above_their_own_level() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (_admin_token, admin_id, mod_token, _mod_id, member_id) = people(&store).await;
    let app = app(store.clone());

    let refused = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{admin_id}/timeout"),
            &mod_token,
            Some(json!({ "duration_seconds": 300 })),
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::FORBIDDEN);

    let removal_refused = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{admin_id}/removal"),
            &mod_token,
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(removal_refused.status(), StatusCode::FORBIDDEN);

    // Fine against an ordinary member, so the refusal is about the target.
    let allowed = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member_id}/timeout"),
            &mod_token,
            Some(json!({ "duration_seconds": 300 })),
        ))
        .await
        .unwrap();
    assert_eq!(allowed.status(), StatusCode::OK);
}

/// An administrator contains every bit, so the containment rule lets them
/// moderate anybody - including another administrator, which in a friend
/// group is a legitimate thing to need.
#[tokio::test]
async fn an_administrator_can_moderate_a_moderator() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (admin_token, _admin_id, _mod_token, mod_id, _member_id) = people(&store).await;
    let app = app(store.clone());

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{mod_id}/timeout"),
            &admin_token,
            Some(json!({ "duration_seconds": 600 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

/// Holding neither bit is a refusal even against somebody junior.
#[tokio::test]
async fn a_plain_member_cannot_moderate_at_all() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (_admin_token, admin_id, _mod_token, mod_id, member_id) = people(&store).await;
    let member_token = store
        .open_session(slimm_server::ids::UserId(member_id.parse().unwrap()), "cli")
        .await
        .unwrap()
        .access_token;
    let app = app(store.clone());

    for target in [&admin_id, &mod_id] {
        let response = app
            .clone()
            .oneshot(request(
                "PUT",
                &format!("/members/{target}/timeout"),
                &member_token,
                Some(json!({ "duration_seconds": 300 })),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }
}

#[tokio::test]
async fn moderating_yourself_is_refused() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (_admin_token, _admin_id, mod_token, mod_id, _member_id) = people(&store).await;
    let app = app(store.clone());

    for (method, path) in [("PUT", "timeout"), ("PUT", "removal")] {
        let response = app
            .clone()
            .oneshot(request(
                method,
                &format!("/members/{mod_id}/{path}"),
                &mod_token,
                Some(json!({ "duration_seconds": 300 })),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "self-moderation via {path}"
        );
    }
}

/// The deadline is computed server-side from a duration, so a client with a
/// skewed clock cannot ask for one already past; the ceiling is what stops a
/// "timeout" that is really a removal wearing the wrong word.
#[tokio::test]
async fn the_duration_is_validated_at_both_ends() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (admin_token, _admin_id, _mod_token, _mod_id, member_id) = people(&store).await;
    let app = app(store.clone());

    for bad in [0, -60, 29 * 24 * 60 * 60, i64::MAX] {
        let response = app
            .clone()
            .oneshot(request(
                "PUT",
                &format!("/members/{member_id}/timeout"),
                &admin_token,
                Some(json!({ "duration_seconds": bad })),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "duration_seconds of {bad} must be refused"
        );
    }
}

/// A removed member is only nameable through the removals listing, and that
/// listing is itself gated - otherwise removal would leak a roster the member
/// list deliberately stopped carrying.
#[tokio::test]
async fn the_removals_listing_needs_the_ban_bit() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (admin_token, _admin_id, _mod_token, _mod_id, member_id) = people(&store).await;
    let member_token = store
        .open_session(slimm_server::ids::UserId(member_id.parse().unwrap()), "cli")
        .await
        .unwrap()
        .access_token;
    let app = app(store.clone());

    let refused = app
        .clone()
        .oneshot(request("GET", "/members/removed", &member_token, None))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::FORBIDDEN);

    let allowed = app
        .clone()
        .oneshot(request("GET", "/members/removed", &admin_token, None))
        .await
        .unwrap();
    assert_eq!(allowed.status(), StatusCode::OK);
}

/// Restoring somebody who was never removed says so, so an undo can be told
/// from a no-op rather than both reporting success.
#[tokio::test]
async fn restoring_someone_who_was_not_removed_is_a_404() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (admin_token, _admin_id, _mod_token, _mod_id, member_id) = people(&store).await;
    let app = app(store.clone());

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{member_id}/removal"),
            &admin_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

/// The refutation that prompted this: a timed-out member whose SEND_MESSAGES
/// is masked could still `PATCH` any message they ever authored to arbitrary
/// new content, because edit gated on VIEW_CHANNEL and then let the author
/// through with no further bit. An edit republishes to the whole channel, so
/// that was a complete substitute for sending.
#[tokio::test]
async fn a_timed_out_author_cannot_edit_their_way_around_the_block() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (admin_token, _admin_id, _mod_token, _mod_id, member_id) = people(&store).await;
    let member = slimm_server::ids::UserId(member_id.parse().unwrap());
    let member_token = store
        .open_session(member, "cli")
        .await
        .unwrap()
        .access_token;
    let channel = store.list_channels().await.unwrap()[0].id;
    let app = app(store.clone());

    let message_id = slimm_server::ids::MessageId::generate();
    store
        .send_message(NewMessage::plain(
            channel,
            member,
            message_id,
            "the original",
        ))
        .await
        .unwrap();

    let edit = |token: String| {
        let app = app.clone();
        async move {
            app.oneshot(request(
                "PATCH",
                &format!("/channels/{channel}/messages/{message_id}"),
                &token,
                Some(json!({ "content": "rewritten" })),
            ))
            .await
            .unwrap()
            .status()
        }
    };

    assert_eq!(edit(member_token.clone()).await, StatusCode::OK);

    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member_id}/timeout"),
            &admin_token,
            Some(json!({ "duration_seconds": 3600 })),
        ))
        .await
        .unwrap();

    assert_eq!(edit(member_token).await, StatusCode::FORBIDDEN);
}

/// Every route that gates on the equal-rank rule, as (verb, path suffix, body).
fn peer_gated_routes() -> Vec<(&'static str, &'static str, serde_json::Value)> {
    vec![
        ("PUT", "timeout", json!({ "duration_seconds": 300 })),
        ("DELETE", "timeout", json!(null)),
        ("PUT", "removal", json!({})),
        ("PUT", "nickname", json!({ "nickname": "renamed" })),
        ("DELETE", "nickname", json!(null)),
    ]
}

async fn refused_as_equal_rank(
    app: &axum::Router,
    token: &str,
    verb: &str,
    uri: &str,
    body: serde_json::Value,
    label: &str,
) {
    let body = (!body.is_null()).then_some(body);
    let refused = app
        .clone()
        .oneshot(request(verb, uri, token, body))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::FORBIDDEN, "{label}");
    let bytes = axum::body::to_bytes(refused.into_body(), usize::MAX)
        .await
        .unwrap();
    assert!(
        String::from_utf8_lossy(&bytes).contains("equal rank"),
        "{label} should say why"
    );
}

/// Two moderators holding the same bits are peers, and neither may act on the other.
#[tokio::test]
async fn a_moderator_cannot_act_on_an_equal_rank_peer() {
    let (store, _guard) = support::new_store("slimm-moderation-routes-test").await;
    let (admin_token, _admin_id, mod_token, mod_id, member_id) = people(&store).await;
    let peer_role = store
        .create_role(
            "mod-two",
            Permissions::KICK_MEMBERS.union(Permissions::BAN_MEMBERS),
            false,
        )
        .await
        .unwrap();
    let peer = store
        .create_account("peer", "Peer", "not-a-real-hash")
        .await
        .unwrap();
    store.assign_role(peer.id, peer_role).await.unwrap();
    let peer_token = store
        .open_session(peer.id, "cli")
        .await
        .unwrap()
        .access_token;
    let app = app(store.clone());

    for (verb, path, body) in peer_gated_routes() {
        let label = format!("{verb} {path}");
        let uri = format!("/members/{}/{path}", peer.id);
        refused_as_equal_rank(&app, &mod_token, verb, &uri, body.clone(), &label).await;
        // The rule is symmetric: the peer cannot reach the first moderator either.
        let back = format!("/members/{mod_id}/{path}");
        refused_as_equal_rank(&app, &peer_token, verb, &back, body, &label).await;
    }

    // Every bulk route shares `authorize_all`, so each refuses the same way with the same reason.
    for (path, body) in [
        (
            "bulk-timeout",
            json!({ "user_ids": [peer.id.to_string()], "duration_seconds": 300 }),
        ),
        ("bulk-removal", json!({ "user_ids": [peer.id.to_string()] })),
    ] {
        let uri = format!("/members/{path}");
        refused_as_equal_rank(&app, &mod_token, "POST", &uri, body, path).await;
    }

    // Strictly lower rank is still within reach, and an administrator outranks the peer.
    let lower = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member_id}/nickname"),
            &mod_token,
            Some(json!({ "nickname": "renamed" })),
        ))
        .await
        .unwrap();
    assert_eq!(lower.status(), StatusCode::NO_CONTENT);
    let by_admin = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{}/timeout", peer.id),
            &admin_token,
            Some(json!({ "duration_seconds": 300 })),
        ))
        .await
        .unwrap();
    assert_eq!(by_admin.status(), StatusCode::OK);
}
