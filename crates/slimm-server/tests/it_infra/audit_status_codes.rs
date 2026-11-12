// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Routes that used to answer 500, an empty message or a silent success for a
//! request that was plainly wrong. Each case names the problem in its 4xx.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::overwrite_harness::{app, new_store, register, request};

struct World {
    router: Router,
    store: Store,
    admin: (String, String),
    member: (String, String),
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-audit-status").await;
    let admin = register(&store, "root").await;
    let member = register(&store, "nia").await;
    World {
        router: app(store.clone()),
        store,
        admin,
        member,
        _guard: guard,
    }
}

impl World {
    async fn call(
        &self,
        method: &str,
        uri: &str,
        token: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let response = self
            .router
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

    async fn as_admin(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        self.call(method, uri, &self.admin.0, body).await
    }
}

fn error_text(body: &Value) -> &str {
    body["error"].as_str().unwrap_or_default()
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

#[tokio::test]
async fn timing_out_an_unknown_user_is_a_404_single_and_bulk() {
    let w = world().await;
    let ghost = uuid::Uuid::now_v7();
    let (status, body) = w
        .as_admin(
            "PUT",
            &format!("/members/{ghost}/timeout"),
            Some(json!({"duration_seconds": 300})),
        )
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(error_text(&body), "no such member");

    let (status, body) = w
        .as_admin(
            "POST",
            "/members/bulk-timeout",
            Some(json!({"user_ids": [ghost.to_string(), w.member.1], "duration_seconds": 300})),
        )
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(error_text(&body), "no such member");
    let member_id = w.member.1.parse().unwrap();
    assert!(
        w.store
            .timed_out_until(slimm_server::ids::UserId(member_id))
            .await
            .unwrap()
            .is_none(),
        "a refused batch moves nobody"
    );
}

#[tokio::test]
async fn an_invite_cannot_be_born_expired_and_revoking_a_stranger_is_a_404() {
    let w = world().await;
    let (status, body) = w
        .as_admin(
            "POST",
            "/invites",
            Some(json!({"expires_at": now_ms() - 1000})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(error_text(&body), "expires_at must be in the future");

    let (status, body) = w.as_admin("DELETE", "/invites/zzzzzzzz", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(error_text(&body), "no such invite");

    let (_, made) = w.as_admin("POST", "/invites", Some(json!({}))).await;
    let code = made["code"].as_str().unwrap().to_owned();
    let uri = format!("/invites/{code}");
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT,
        "revoking your own revoked invite again is still a retry, not an error"
    );
}

#[tokio::test]
async fn a_role_order_that_repeats_an_id_names_it() {
    let w = world().await;
    let (_, first) = w
        .as_admin(
            "POST",
            "/roles",
            Some(json!({"name": "alpha", "permissions": 0})),
        )
        .await;
    let (_, second) = w
        .as_admin(
            "POST",
            "/roles",
            Some(json!({"name": "beta", "permissions": 0})),
        )
        .await;
    let _ = (first, second);
    let (_, roles) = w.as_admin("GET", "/roles", None).await;
    let live: Vec<String> = roles
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["is_everyone"] == false)
        .map(|r| r["id"].as_str().unwrap().to_owned())
        .collect();
    let repeated = live[0].clone();
    let mut ids = live.clone();
    ids.push(repeated.clone());
    let (status, body) = w
        .as_admin("PATCH", "/roles/reorder", Some(json!({"role_ids": ids})))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(error_text(&body).contains(&repeated), "{body}");
}

#[tokio::test]
async fn an_overwrite_cannot_allow_and_deny_one_bit_nor_name_a_target_twice() {
    let w = world().await;
    let channel = support::overwrite_harness::general_channel_id(&w.store).await;
    let (_, role) = w
        .as_admin(
            "POST",
            "/roles",
            Some(json!({"name": "helper", "permissions": 0})),
        )
        .await;
    let role_id = role["id"].as_str().unwrap();

    let uri = format!("/channels/{channel}/overwrites");
    let (status, body) = w
        .as_admin(
            "PUT",
            &uri,
            Some(json!({"overwrites": [{"kind": "role", "id": role_id, "allow": 4, "deny": 4}]})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(error_text(&body).contains("allow and deny"), "{body}");

    let (status, body) = w
        .as_admin(
            "PUT",
            &uri,
            Some(json!({"overwrites": [
                {"kind": "role", "id": role_id, "allow": 4, "deny": 0},
                {"kind": "role", "id": role_id, "allow": 2, "deny": 0},
            ]})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(error_text(&body).contains("more than once"), "{body}");

    let single = format!("/channels/{channel}/overwrites/role/{role_id}");
    let (status, body) = w
        .as_admin("PUT", &single, Some(json!({"allow": 4, "deny": 4})))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
}

#[tokio::test]
async fn creating_with_the_id_of_a_deleted_channel_is_a_conflict() {
    let w = world().await;
    let id = uuid::Uuid::now_v7().to_string();
    let (status, live) = w
        .as_admin(
            "POST",
            "/channels",
            Some(json!({"id": id, "name": "first"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{live}");
    let (status, replay) = w
        .as_admin(
            "POST",
            "/channels",
            Some(json!({"id": id, "name": "first"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        replay["id"], live["id"],
        "a live id replays as the same channel"
    );

    assert_eq!(
        w.as_admin("DELETE", &format!("/channels/{id}"), None)
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    let (status, body) = w
        .as_admin(
            "POST",
            "/channels",
            Some(json!({"id": id, "name": "zombie"})),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(
        error_text(&body),
        "that channel id belonged to a channel that was deleted"
    );
}

#[tokio::test]
async fn join_muted_is_refused_on_a_text_channel_create_and_update() {
    let w = world().await;
    let (status, body) = w
        .as_admin(
            "POST",
            "/channels",
            Some(json!({"name": "txt", "kind": "text", "join_muted": true})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(error_text(&body).contains("voice"), "{body}");

    let (_, text) = w
        .as_admin("POST", "/channels", Some(json!({"name": "txt"})))
        .await;
    let (status, body) = w
        .as_admin(
            "PATCH",
            &format!("/channels/{}", text["id"].as_str().unwrap()),
            Some(json!({"join_muted": true})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");

    let (status, voice) = w
        .as_admin(
            "POST",
            "/channels",
            Some(json!({"name": "vc", "kind": "voice", "join_muted": true})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{voice}");
    assert_eq!(voice["join_muted"], true);
}

#[tokio::test]
async fn deleting_an_account_that_is_already_gone_is_a_404() {
    let w = world().await;
    let uri = format!("/members/{}/account", w.member.1);
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    let (status, body) = w.as_admin("DELETE", &uri, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(error_text(&body), "no such member");
    let ghost = format!("/members/{}/account", uuid::Uuid::now_v7());
    assert_eq!(
        w.as_admin("DELETE", &ghost, None).await.0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn a_reaction_must_be_an_emoji_a_shortcode_or_a_custom_emoji_id() {
    let w = world().await;
    let channel = support::overwrite_harness::general_channel_id(&w.store).await;
    let (status, sent) = w
        .as_admin(
            "POST",
            &format!("/channels/{channel}/messages"),
            Some(json!({"id": uuid::Uuid::now_v7().to_string(), "content": "hi"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{sent}");
    let message = sent["id"].as_str().unwrap();
    let react = |emoji: &str| format!("/messages/{message}/reactions/{}", encode(emoji));

    let accepted = [
        "\u{1F44D}",
        "\u{2764}\u{FE0F}",
        "\u{1F44D}\u{1F3FD}",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        "\u{1F1E8}\u{1F1E6}",
        "1\u{FE0F}\u{20E3}",
        ":party_parrot:",
        &uuid::Uuid::now_v7().to_string(),
    ];
    for emoji in accepted {
        let (status, body) = w.as_admin("PUT", &react(emoji), None).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{emoji:?} {body}");
    }
    let refused = [
        "hello world",
        "hello",
        "\u{1F44D}\u{1F44D}",
        "\u{1F44D}x",
        ":not a code:",
        "::",
        ":a:b:",
        "a",
        "\u{202E}",
    ];
    for text in refused {
        let (status, body) = w.as_admin("PUT", &react(text), None).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{text:?}");
        assert_eq!(error_text(&body), "that is not a usable emoji");
    }
}

fn encode(text: &str) -> String {
    text.bytes().map(|b| format!("%{b:02X}")).collect()
}
