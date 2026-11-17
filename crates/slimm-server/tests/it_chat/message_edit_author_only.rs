// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Only a message's author edits it: a moderator or an administrator gets a
//! coded 403 and the text stays as written, while a moderator still deletes
//! it and a bot still edits its own.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{json_body, register_token_id as register, request};

struct World {
    app: Router,
    store: Store,
    messages: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-msg-edit-author").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = support::app::builder(store.clone())
        .auth(Auth::new(2).expect("auth service"))
        .router();
    World {
        app,
        store,
        messages: format!("/channels/{}/messages", channel.id),
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
            .app
            .clone()
            .oneshot(request(method, uri, Some(token), body))
            .await
            .unwrap();
        let status = response.status();
        let body = match status {
            StatusCode::NO_CONTENT => Value::Null,
            _ => json_body(response).await,
        };
        (status, body)
    }

    async fn send(&self, token: &str, content: &str) -> String {
        let id = Uuid::now_v7().to_string();
        let body = json!({ "id": id, "content": content });
        let (status, _) = self.call("POST", &self.messages, token, Some(body)).await;
        assert_eq!(status, StatusCode::OK);
        format!("{}/{id}", self.messages)
    }

    async fn edit(&self, token: &str, message: &str, content: &str) -> (StatusCode, Value) {
        let body = json!({ "content": content });
        self.call("PATCH", message, token, Some(body)).await
    }

    async fn member_with(&self, username: &str, permissions: Permissions) -> String {
        let (token, id) = register(&self.store, username).await;
        let role = self
            .store
            .create_role(username, permissions, false)
            .await
            .unwrap();
        let user = UserId(Uuid::parse_str(&id).unwrap());
        self.store.assign_role(user, role).await.unwrap();
        token
    }
}

#[tokio::test]
async fn nobody_but_the_author_edits_a_message() {
    let w = world().await;
    let (alice, _) = register(&w.store, "alice").await;
    let message = w.send(&alice, "alice's words").await;
    let (bob, _) = register(&w.store, "bob").await;
    let moderator = w.member_with("mod", Permissions::MANAGE_MESSAGES).await;
    let admin = w.member_with("admin", Permissions::ADMINISTRATOR).await;

    for token in [&bob, &moderator, &admin] {
        let (status, body) = w.edit(token, &message, "someone else's words").await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
        assert_eq!(body["code"], "not_author", "{body}");
    }
    let (_, stored) = w.call("GET", &message, &alice, None).await;
    assert_eq!(stored["content"], "alice's words");
    assert!(stored["edited_at"].is_null());

    let (status, body) = w.edit(&alice, &message, "alice, edited").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["content"], "alice, edited");
}

#[tokio::test]
async fn a_moderator_still_deletes_someone_elses_message() {
    let w = world().await;
    let (alice, _) = register(&w.store, "alice").await;
    let message = w.send(&alice, "to be removed").await;
    let moderator = w.member_with("mod", Permissions::MANAGE_MESSAGES).await;

    let (status, _) = w.call("DELETE", &message, &moderator, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_bot_edits_its_own_message() {
    let w = world().await;
    let (_, admin_id) = register(&w.store, "root").await;
    let bot = w
        .store
        .create_bot(
            "helper",
            "Helper",
            Permissions::NONE,
            UserId(Uuid::parse_str(&admin_id).unwrap()),
        )
        .await
        .unwrap();
    let message = w.send(&bot.token, "build started").await;

    let (status, body) = w.edit(&bot.token, &message, "build passed").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["content"], "build passed");
}
