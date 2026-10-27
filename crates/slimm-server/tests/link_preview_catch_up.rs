// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A link-preview removal reaches a client that was offline through `/sync`
//! as an edit op, survives an edit in the edit response and the live frame,
//! and an author who could not edit the message cannot remove its previews.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::Event;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::RoleChanges;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{builder, register_token_id as register, request};
use support::ws::{connect, read_frame_skipping_presence_timed, serve, user_ticket};

struct World {
    store: slimm_server::store::Store,
    state: slimm_server::http::AppState,
    app: axum::Router,
    channel: String,
    author: String,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let (store, guard) = support::new_store(prefix).await;
    let state = builder(store.clone()).build();
    let app = slimm_server::http::router(state.clone());
    // The first account claims the deployment as admin, whose bits bypass every check.
    let _admin = register(&store, "admin").await;
    let (author, _) = register(&store, "author").await;
    let channel = store
        .create_channel("links", "text")
        .await
        .unwrap()
        .id
        .to_string();
    World {
        store,
        state,
        app,
        channel,
        author,
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
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn send(&self, content: &str) -> String {
        let (status, body) = self
            .call(
                "POST",
                &format!("/channels/{}/messages", self.channel),
                &self.author,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            )
            .await;
        assert_eq!(status, StatusCode::OK);
        body["id"].as_str().unwrap().to_owned()
    }

    async fn remove_previews(&self, token: &str, message: &str) -> StatusCode {
        let uri = format!(
            "/channels/{}/messages/{message}/link-previews",
            self.channel
        );
        self.call("DELETE", &uri, token, None).await.0
    }

    async fn ops_after(&self, cursor: i64) -> Value {
        let (status, body) = self
            .call(
                "POST",
                "/sync",
                &self.author,
                Some(json!({ "scopes": [
                    { "channel_id": self.channel, "after_seq": 99, "after_op_seq": cursor }
                ] })),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["scopes"][0].clone()
    }
}

#[tokio::test]
async fn an_offline_client_learns_of_a_removal_from_sync() {
    let w = world("slimm-lp-catch-up").await;
    let kept = w.send("see https://example.com/a").await;
    let removed = w.send("see https://example.com/b").await;
    let mut events = w.state.hub.subscribe();

    assert!(w.ops_after(0).await["ops"].as_array().unwrap().is_empty());
    assert_eq!(
        w.remove_previews(&w.author, &removed).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        w.remove_previews(&w.author, &removed).await,
        StatusCode::NO_CONTENT
    );

    let scope = w.ops_after(0).await;
    let ops = scope["ops"].as_array().unwrap();
    assert_eq!(ops.len(), 1, "the repeat removal wrote no second op");
    assert_eq!(ops[0]["kind"], "edit");
    assert_eq!(ops[0]["message_id"], removed);
    assert_eq!(ops[0]["content"], "see https://example.com/b");
    assert_eq!(ops[0]["link_previews_removed"], true);
    assert_eq!(scope["op_latest_seq"], 1);
    assert!(ops.iter().all(|op| op["message_id"] != kept));

    let mut frame_ops = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let Event::MessageLinkPreviewsRemoved { op_seq, .. } = event {
            frame_ops.push(op_seq);
        }
    }
    assert_eq!(
        frame_ops,
        vec![1],
        "the live event names the op a sync would carry"
    );
}

#[tokio::test]
async fn an_edit_after_a_removal_keeps_the_flag_everywhere() {
    let w = world("slimm-lp-edit-after").await;
    let message = w.send("see https://example.com/a").await;
    assert_eq!(
        w.remove_previews(&w.author, &message).await,
        StatusCode::NO_CONTENT
    );

    let addr = serve(w.state.clone()).await;
    let (_, ticket, _) = user_ticket(&w.store, "reader").await;
    let mut reader = connect(addr, &ticket).await;

    let (status, edited) = w
        .call(
            "PATCH",
            &format!("/channels/{}/messages/{message}", w.channel),
            &w.author,
            Some(json!({ "content": "see https://example.com/a again" })),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(edited["link_previews_removed"], true, "edit response");

    let frame = loop {
        let frame = read_frame_skipping_presence_timed(&mut reader).await;
        if frame["type"] == "message.edited" {
            break frame;
        }
    };
    assert_eq!(
        frame["message"]["link_previews_removed"], true,
        "live frame"
    );

    let scope = w.ops_after(0).await;
    let flags: Vec<&Value> = scope["ops"]
        .as_array()
        .unwrap()
        .iter()
        .map(|op| &op["link_previews_removed"])
        .collect();
    assert_eq!(flags, vec![&json!(true), &json!(true)]);
}

#[tokio::test]
async fn an_author_who_cannot_send_cannot_remove_previews_but_a_moderator_can() {
    let w = world("slimm-lp-send-gate").await;
    let message = w.send("see https://example.com/a").await;
    let everyone = w
        .store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap();
    w.store
        .update_role(
            everyone.id,
            RoleChanges {
                permissions: Some(Permissions::VIEW_CHANNEL),
                ..RoleChanges::default()
            },
        )
        .await
        .unwrap();

    assert_eq!(
        w.remove_previews(&w.author, &message).await,
        StatusCode::FORBIDDEN
    );

    let (moderator, moderator_id) = register(&w.store, "moderator").await;
    let mods = w
        .store
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    w.store
        .assign_role(UserId(Uuid::parse_str(&moderator_id).unwrap()), mods)
        .await
        .unwrap();
    assert_eq!(
        w.remove_previews(&moderator, &message).await,
        StatusCode::NO_CONTENT
    );
}
