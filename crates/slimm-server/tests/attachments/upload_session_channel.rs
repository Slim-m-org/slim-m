// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A resumable upload that names its channel is held to that channel's
//! ATTACH_FILES, when it is opened and again when it completes.
//!
//! The deployment-wide path was covered; the `channel_id` branch of
//! `may_attach` was only ever exercised on the allowing side.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{OverwriteBatchEntry, Store};
use tower::ServiceExt;

use crate::fixtures::*;

struct World {
    store: Store,
    app: Router,
    member: String,
    locked: ChannelId,
    open: ChannelId,
    everyone: uuid::Uuid,
    _guard: crate::support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store().await;
    let (_admin, _) = register(&store, "root").await;
    let everyone = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .expect("bootstrap seeds @everyone")
        .id;
    store
        .update_role(
            everyone,
            slimm_server::store::RoleChanges {
                permissions: Some(Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES)),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    let locked = store.create_channel("locked", "text").await.unwrap().id;
    let open = store.create_channel("open", "text").await.unwrap().id;
    let (member, _) = register(&store, "nia").await;
    let app = app(store.clone());
    World {
        store,
        app,
        member,
        locked,
        open,
        everyone: everyone.0,
        _guard: guard,
    }
}

impl World {
    async fn deny_attach(&self, channel: ChannelId) {
        self.store
            .set_channel_overwrites_batch(
                channel,
                &[OverwriteBatchEntry {
                    target_type: "role",
                    target_id: self.everyone,
                    allow: Permissions::NONE,
                    deny: Permissions::ATTACH_FILES,
                }],
            )
            .await
            .unwrap();
    }

    async fn open_session(&self, channel: Option<ChannelId>) -> (StatusCode, String) {
        let mut body = json!({ "filename": "a.png", "size": png(4).len() });
        if let Some(channel) = channel {
            body["channel_id"] = json!(channel.to_string());
        }
        let response = self
            .app
            .clone()
            .oneshot(request_json(
                "POST",
                "/attachments/uploads",
                &self.member,
                body,
            ))
            .await
            .unwrap();
        let status = response.status();
        let id = json_body(response).await["id"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        (status, id)
    }

    async fn upload_all(&self, id: &str) {
        let response = self
            .app
            .clone()
            .oneshot(request_bytes(
                "PUT",
                &format!("/attachments/uploads/{id}?offset=0"),
                &self.member,
                png(4),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    async fn complete(&self, id: &str, channel: Option<ChannelId>) -> StatusCode {
        let query = channel.map_or(String::new(), |c| format!("?channel_id={c}"));
        self.app
            .clone()
            .oneshot(request_plain(
                "POST",
                &format!("/attachments/uploads/{id}/complete{query}"),
                &self.member,
            ))
            .await
            .unwrap()
            .status()
    }
}

#[tokio::test]
async fn a_channel_overwrite_denying_attach_files_refuses_opening_a_session_for_it() {
    let w = world().await;
    w.deny_attach(w.locked).await;

    assert_eq!(
        w.open_session(Some(w.locked)).await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(w.open_session(Some(w.open)).await.0, StatusCode::CREATED);
    assert_eq!(w.open_session(None).await.0, StatusCode::CREATED);
}

#[tokio::test]
async fn permission_revoked_between_open_and_complete_refuses_the_completion() {
    let w = world().await;
    let (status, id) = w.open_session(Some(w.locked)).await;
    assert_eq!(status, StatusCode::CREATED);
    w.upload_all(&id).await;

    w.deny_attach(w.locked).await;

    assert_eq!(w.complete(&id, Some(w.locked)).await, StatusCode::FORBIDDEN);
    // Refused before the session is spent, so the same upload still finishes where it is allowed.
    assert_eq!(w.complete(&id, Some(w.open)).await, StatusCode::CREATED);
}
