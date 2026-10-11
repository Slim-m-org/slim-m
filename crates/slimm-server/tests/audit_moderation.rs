// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The moderation trail and the events beside it: irreversible admin acts are
//! logged, a write that changes nothing publishes nothing, the Roles pane
//! counts what the member list shows, and reports refuse nonsense.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::sync::broadcast::Receiver;
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{
    KNOWN_PASSWORD, new_store, register, register_with_password, request,
};

struct World {
    router: Router,
    store: Store,
    events: Receiver<Event>,
    admin: (String, String),
    member: (String, String),
    other: (String, String),
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-audit-moderation").await;
    let admin = register_with_password(&store, "root").await;
    let member = register(&store, "nia").await;
    let other = register(&store, "omar").await;
    let hub = Hub::new();
    let events = hub.subscribe();
    let router = http::router(AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub,
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    World {
        router,
        store,
        events,
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

    async fn admin(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        self.call(method, uri, &self.admin.0, body).await
    }

    fn drain(&mut self) -> usize {
        let mut seen = 0;
        while self.events.try_recv().is_ok() {
            seen += 1;
        }
        seen
    }

    async fn audit_actions(&self) -> Vec<String> {
        let (_, history) = self.admin("GET", "/reports/history?limit=60", None).await;
        history
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["kind"] == "audit_log")
            .map(|item| item["action"].as_str().unwrap().to_owned())
            .collect()
    }
}

#[tokio::test]
async fn account_deletion_and_reset_codes_are_in_the_audit_log() {
    let w = world().await;
    let (status, _) = w
        .admin(
            "POST",
            &format!("/admin/users/{}/reset-code", w.member.1),
            Some(json!({ "password": KNOWN_PASSWORD })),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = w
        .admin("DELETE", &format!("/members/{}/account", w.other.1), None)
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (_, history) = w.admin("GET", "/reports/history?limit=60", None).await;
    let entries = history.as_array().unwrap();
    let find = |action: &str| entries.iter().find(|e| e["action"] == action).cloned();
    let issued = find("reset_code_issue").expect("reset code issue is logged");
    assert_eq!(issued["actor_id"], w.admin.1);
    assert_eq!(issued["subject_id"], w.member.1);
    let deleted = find("account_delete").expect("account deletion is logged");
    assert_eq!(deleted["actor_id"], w.admin.1);
    assert_eq!(deleted["subject_id"], w.other.1);
}

#[tokio::test]
async fn deleting_your_own_account_is_not_a_moderation_act() {
    let w = world().await;
    let (token, _) = register_with_password(&w.store, "dee").await;
    let (status, _) = w
        .call(
            "DELETE",
            "/account",
            &token,
            Some(json!({ "password": KNOWN_PASSWORD })),
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(w.audit_actions().await.is_empty());
}

#[tokio::test]
async fn a_moderation_write_that_changes_nothing_publishes_nothing() {
    let mut w = world().await;
    let role = w
        .store
        .create_role(
            "helper",
            slimm_server::permissions::Permissions::NONE,
            false,
        )
        .await
        .unwrap();
    let timeout = format!("/members/{}/timeout", w.member.1);
    let holds = format!("/members/{}/roles/{role}", w.member.1);
    w.drain();

    for (method, uri) in [("DELETE", &timeout), ("DELETE", &holds)] {
        let (status, _) = w.admin(method, uri, None).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        assert_eq!(w.drain(), 0, "{method} {uri} changed nothing");
    }

    let (status, _) = w.admin("PUT", &holds, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(w.drain(), 1, "a real grant is announced once");
    w.admin("PUT", &holds, None).await;
    assert_eq!(w.drain(), 0, "granting what is held changes nothing");

    let (status, _) = w
        .admin("PUT", &timeout, Some(json!({"duration_seconds": 300})))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(w.drain(), 1);
    w.admin("DELETE", &timeout, None).await;
    assert_eq!(w.drain(), 1, "lifting a real timeout is announced");
    w.admin("DELETE", &holds, None).await;
    assert_eq!(w.drain(), 1, "removing a held role is announced");
}

#[tokio::test]
async fn a_timeout_set_to_the_value_it_already_has_changes_nothing() {
    let w = world().await;
    let until = i64::MAX / 4;
    let member = w.store.clone();
    let user = slimm_server::ids::UserId(w.member.1.parse().unwrap());
    let actor = slimm_server::ids::UserId(w.admin.1.parse().unwrap());
    assert!(
        member
            .set_member_timeout(user, until, Some("calm"), actor)
            .await
            .unwrap()
    );
    assert!(
        !member
            .set_member_timeout(user, until, Some("calm"), actor)
            .await
            .unwrap()
    );
    assert!(
        member
            .set_member_timeout(user, until, Some("other"), actor)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn everyone_counts_the_members_the_list_shows_not_webhooks() {
    let w = world().await;
    let general = support::overwrite_harness::general_channel_id(&w.store).await;
    for label in ["one", "two"] {
        let (status, _) = w
            .admin(
                "POST",
                "/webhooks",
                Some(json!({"channel_id": general, "label": label})),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED);
    }
    let (_, members) = w.admin("GET", "/members", None).await;
    let (_, roles) = w.admin("GET", "/roles", None).await;
    let everyone = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["is_everyone"] == true)
        .unwrap();
    assert_eq!(everyone["member_count"], members.as_array().unwrap().len());
}

#[tokio::test]
async fn reports_refuse_yourself_and_a_second_resolution() {
    let w = world().await;
    let general = support::overwrite_harness::general_channel_id(&w.store).await;
    let (_, sent) = w
        .call(
            "POST",
            &format!("/channels/{general}/messages"),
            &w.member.0,
            Some(json!({"id": uuid::Uuid::now_v7().to_string(), "content": "mine"})),
        )
        .await;
    let own_message = sent["id"].as_str().unwrap();
    for (kind, subject) in [("user", w.member.1.as_str()), ("message", own_message)] {
        let (status, body) = w
            .call(
                "POST",
                "/reports",
                &w.member.0,
                Some(json!({"subject_kind": kind, "subject_id": subject, "reason": "x"})),
            )
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{kind} {body}");
        assert!(
            body["error"].as_str().unwrap().contains("cannot report"),
            "{body}"
        );
    }

    let (status, filed) = w
        .call(
            "POST",
            "/reports",
            &w.other.0,
            Some(json!({"subject_kind": "message", "subject_id": own_message, "reason": "spam"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{filed}");
    let uri = format!("/reports/{}", filed["id"].as_str().unwrap());
    let resolve = |resolution: &str| json!({ "resolution": resolution });
    assert_eq!(
        w.admin("PATCH", &uri, Some(resolve("resolved"))).await.0,
        StatusCode::NO_CONTENT
    );
    let (status, body) = w.admin("PATCH", &uri, Some(resolve("dismissed"))).await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"], "that report is already resolved");
}
