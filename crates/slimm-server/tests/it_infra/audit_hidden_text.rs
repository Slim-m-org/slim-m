// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Free text other members read goes through the one hidden-character
//! classifier on write, and a row that already holds such a character can
//! still be read and edited to a clean value.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::overwrite_harness::{app, new_store, register, request};

const BIDI: &str = "ad\u{202E}min";
const BLANK: &str = "ad\u{3164}min";
const BELL: &str = "ad\u{7}min";

struct World {
    router: Router,
    store: Store,
    admin: (String, String),
    member: (String, String),
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-audit-hidden").await;
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
    async fn send(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let response = self
            .router
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

    async fn admin(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        self.send(method, uri, Some(&self.admin.0), body).await
    }
}

fn names_field(body: &Value, field: &str) -> bool {
    let text = body["error"].as_str().unwrap_or_default();
    text.starts_with(field) && text.contains("invisible")
}

#[tokio::test]
async fn a_timeout_removal_or_report_reason_refuses_hidden_characters() {
    let w = world().await;
    for bad in [BIDI, BLANK, BELL] {
        let uri = format!("/members/{}/timeout", w.member.1);
        let (status, body) = w
            .admin(
                "PUT",
                &uri,
                Some(json!({"duration_seconds": 60, "reason": bad})),
            )
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad:?} {body}");
        assert!(names_field(&body, "reason"), "{body}");
    }
    let (status, _) = w
        .admin(
            "PUT",
            &format!("/members/{}/timeout", w.member.1),
            Some(json!({"duration_seconds": 60, "reason": "line one\nline two"})),
        )
        .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "a multi-line reason is ordinary text"
    );

    let (status, body) = w
        .send(
            "POST",
            "/reports",
            Some(&w.member.0),
            Some(json!({"subject_kind": "user", "subject_id": w.admin.1, "reason": BIDI})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(names_field(&body, "reason"), "{body}");
}

#[tokio::test]
async fn a_webhook_username_override_refuses_hidden_characters() {
    let w = world().await;
    let channel = support::overwrite_harness::general_channel_id(&w.store).await;
    let (_, made) = w
        .admin(
            "POST",
            "/webhooks",
            Some(json!({"channel_id": channel, "label": "hook"})),
        )
        .await;
    let path = made["delivery_path"].as_str().unwrap().to_owned();
    for bad in [BIDI, BLANK] {
        let (status, body) = w
            .send(
                "POST",
                &path,
                None,
                Some(json!({"content": "x", "username": bad})),
            )
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad:?} {body}");
        assert!(names_field(&body, "username"), "{body}");
    }
    let (status, _) = w
        .send(
            "POST",
            &path,
            None,
            Some(json!({"content": "x", "username": "Deploys"})),
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn channel_category_and_role_names_and_topics_refuse_hidden_characters() {
    let w = world().await;
    let general = support::overwrite_harness::general_channel_id(&w.store).await;
    for bad in [BIDI, BLANK] {
        let cases = [
            ("POST", "/channels".to_owned(), json!({"name": bad}), "name"),
            (
                "PATCH",
                format!("/channels/{general}"),
                json!({"name": bad}),
                "name",
            ),
            (
                "PATCH",
                format!("/channels/{general}"),
                json!({"topic": bad}),
                "topic",
            ),
            (
                "POST",
                "/categories".to_owned(),
                json!({"name": bad}),
                "name",
            ),
            (
                "POST",
                "/roles".to_owned(),
                json!({"name": bad, "permissions": 0}),
                "name",
            ),
        ];
        for (method, uri, body, field) in cases {
            let (status, answer) = w.admin(method, &uri, Some(body)).await;
            assert_eq!(
                status,
                StatusCode::BAD_REQUEST,
                "{method} {uri} {bad:?} {answer}"
            );
            assert!(names_field(&answer, field), "{uri} {answer}");
        }
    }
}

#[tokio::test]
async fn a_stored_name_with_a_hidden_character_can_still_be_read_and_cleaned() {
    let w = world().await;
    let channel = w.store.create_channel(BIDI, "text").await.unwrap();
    let category = w.store.create_category(BIDI).await.unwrap();
    let role = w
        .store
        .create_role(BIDI, slimm_server::permissions::Permissions::NONE, false)
        .await
        .unwrap();

    let (status, listed) = w.admin("GET", "/channels", None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(listed.as_array().unwrap().iter().any(|c| c["name"] == BIDI));

    let uri = format!("/channels/{}", channel.id);
    let (status, body) = w.admin("PATCH", &uri, Some(json!({"topic": "calm"}))).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "editing another field leaves the name alone: {body}"
    );
    assert_eq!(body["name"], BIDI);
    let (status, body) = w.admin("PATCH", &uri, Some(json!({"name": "admin"}))).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["name"], "admin");

    let (status, _) = w
        .admin(
            "PATCH",
            &format!("/categories/{}", category.id),
            Some(json!({"name": "clean"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = w
        .admin(
            "PATCH",
            &format!("/roles/{role}"),
            Some(json!({"name": "clean"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn poll_text_and_embed_headings_refuse_hidden_characters() {
    let w = world().await;
    let channel = support::overwrite_harness::general_channel_id(&w.store).await;
    let uri = format!("/channels/{channel}/messages/polls");
    let poll = |question: &str, options: Value| json!({"id": uuid::Uuid::now_v7().to_string(), "question": question, "options": options});
    let (status, body) = w
        .admin("POST", &uri, Some(poll(BIDI, json!(["a", "b"]))))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(names_field(&body, "poll question"), "{body}");
    let (status, body) = w
        .admin("POST", &uri, Some(poll("fine", json!(["a", BLANK]))))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(names_field(&body, "poll option"), "{body}");

    let (_, made) = w
        .admin(
            "POST",
            "/webhooks",
            Some(json!({"channel_id": channel, "label": "hook"})),
        )
        .await;
    let hook = made["delivery_path"].as_str().unwrap().to_owned();
    let send = |embed: Value| json!({"content": "x", "embeds": [embed]});
    for (embed, field) in [
        (json!({"title": BIDI}), "an embed title"),
        (json!({"author": {"name": BLANK}}), "an embed author name"),
        (json!({"footer": {"text": BIDI}}), "an embed footer"),
        (
            json!({"fields": [{"name": BIDI, "value": "v"}]}),
            "an embed field name",
        ),
    ] {
        let (status, body) = w.send("POST", &hook, None, Some(send(embed))).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{field} {body}");
        assert!(names_field(&body, field), "{body}");
    }
}
