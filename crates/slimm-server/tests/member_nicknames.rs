// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Decision 0055: an administrator can give another member or bot a
//! space-local display name that every reader sees, without touching the
//! account's own name.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, new_store, register, request};

struct World {
    router: Router,
    admin: (String, String),
    member: (String, String),
    other: (String, String),
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-member-nicknames").await;
    let admin = register(&store, "root").await;
    let member = register(&store, "nia").await;
    let other = register(&store, "omar").await;
    World {
        router: app(store),
        admin,
        member,
        other,
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

    async fn rename(&self, who: &str, nickname: &str) -> (StatusCode, Value) {
        self.call(
            "PUT",
            &format!("/members/{who}/nickname"),
            &self.admin.0,
            Some(json!({ "nickname": nickname })),
        )
        .await
    }
}

#[tokio::test]
async fn an_admin_renames_a_member_and_every_reader_sees_it() {
    let w = world().await;
    let (status, _) = w.rename(&w.member.1, "Nia the Great").await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (_, profile) = w
        .call("GET", &format!("/users/{}", w.member.1), &w.other.0, None)
        .await;
    assert_eq!(profile["display_name"], "Nia the Great");
    assert_eq!(profile["nickname"], "Nia the Great");
    assert_eq!(profile["account_display_name"], "nia");

    let (_, members) = w.call("GET", "/members", &w.other.0, None).await;
    let listed = members
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == w.member.1.as_str())
        .cloned()
        .unwrap();
    assert_eq!(listed["display_name"], "Nia the Great");
}

#[tokio::test]
async fn the_account_keeps_its_own_name_in_its_own_session() {
    let w = world().await;
    w.rename(&w.member.1, "Renamed").await;
    let (_, me) = w.call("GET", "/me", &w.member.0, None).await;
    assert_eq!(me["display_name"], "nia");
}

#[tokio::test]
async fn clearing_restores_the_account_name() {
    let w = world().await;
    w.rename(&w.member.1, "Renamed").await;
    let (status, _) = w
        .call(
            "DELETE",
            &format!("/members/{}/nickname", w.member.1),
            &w.admin.0,
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, profile) = w
        .call("GET", &format!("/users/{}", w.member.1), &w.other.0, None)
        .await;
    assert_eq!(profile["display_name"], "nia");
    assert!(profile["nickname"].is_null());
}

#[tokio::test]
async fn an_ordinary_member_cannot_rename_anyone() {
    let w = world().await;
    let (status, _) = w
        .call(
            "PUT",
            &format!("/members/{}/nickname", w.other.1),
            &w.member.0,
            Some(json!({ "nickname": "Nope" })),
        )
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn hidden_blank_and_overlong_names_are_refused() {
    let w = world().await;
    for bad in ["", "   ", "a\u{202E}b", "a\u{200B}b", &"x".repeat(65)] {
        let (status, _) = w.rename(&w.member.1, bad).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad:?}");
    }
}

#[tokio::test]
async fn a_bot_can_be_renamed_too() {
    let w = world().await;
    let (_, bot) = w
        .call(
            "POST",
            "/bots",
            &w.admin.0,
            Some(json!({ "username": "tuner", "display_name": "Tuner" })),
        )
        .await;
    let bot_id = bot["bot"]["user_id"]
        .as_str()
        .or_else(|| bot["user_id"].as_str())
        .unwrap()
        .to_owned();
    let (status, _) = w.rename(&bot_id, "House DJ").await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, profile) = w
        .call("GET", &format!("/users/{bot_id}"), &w.other.0, None)
        .await;
    assert_eq!(profile["display_name"], "House DJ");
}

#[tokio::test]
async fn renames_and_clears_are_in_the_audit_log() {
    let w = world().await;
    w.rename(&w.member.1, "Renamed").await;
    w.call(
        "DELETE",
        &format!("/members/{}/nickname", w.member.1),
        &w.admin.0,
        None,
    )
    .await;
    let (_, history) = w
        .call("GET", "/reports/history?limit=60", &w.admin.0, None)
        .await;
    let actions: Vec<&str> = history
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|e| e["action"].as_str())
        .collect();
    assert!(actions.contains(&"nickname_set"), "{actions:?}");
    assert!(actions.contains(&"nickname_clear"), "{actions:?}");
}

#[tokio::test]
async fn an_admin_cannot_rename_a_more_powerful_account() {
    let w = world().await;
    let (status, _) = w
        .call(
            "PUT",
            &format!("/members/{}/nickname", w.admin.1),
            &w.member.0,
            Some(json!({ "nickname": "Boss" })),
        )
        .await;
    assert_ne!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_direct_message_list_shows_the_nickname() {
    let w = world().await;
    w.call("POST", &format!("/dms/{}", w.member.1), &w.other.0, None)
        .await;
    w.rename(&w.member.1, "Renamed").await;
    let (_, dms) = w.call("GET", "/dms", &w.other.0, None).await;
    assert_eq!(dms[0]["user"]["display_name"], "Renamed");
}
