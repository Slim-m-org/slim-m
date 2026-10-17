// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! ATTACH_FILES granted by a channel overwrite lets a member upload for that
//! channel, through both the single request and a resumable session
//! (issue 1796).

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::{OverwriteBatchEntry, RoleChanges};
use tower::ServiceExt;

use crate::fixtures::*;

#[tokio::test]
async fn an_overwrite_granting_attach_files_allows_an_upload_for_that_channel() {
    let (store, _guard) = new_store().await;
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
            RoleChanges {
                permissions: Some(Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES)),
                ..RoleChanges::default()
            },
        )
        .await
        .unwrap();
    let channel = store.create_channel("media", "text").await.unwrap();
    let elsewhere = store.create_channel("talk", "text").await.unwrap();
    store
        .set_channel_overwrites_batch(
            channel.id,
            &[OverwriteBatchEntry {
                target_type: "role",
                target_id: everyone.0,
                allow: Permissions::ATTACH_FILES,
                deny: Permissions::NONE,
            }],
        )
        .await
        .unwrap();
    let (member, _) = register(&store, "nia").await;
    let app = app(store);
    let post = |uri: String| {
        let app = app.clone();
        let member = member.clone();
        async move {
            app.oneshot(request_bytes("POST", &uri, &member, png(4)))
                .await
                .unwrap()
                .status()
        }
    };

    assert_eq!(
        post("/attachments?filename=a.png".into()).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        post(format!(
            "/attachments?filename=a.png&channel_id={}",
            elsewhere.id
        ))
        .await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        post(format!(
            "/attachments?filename=a.png&channel_id={}",
            channel.id
        ))
        .await,
        StatusCode::CREATED
    );

    let session = app
        .clone()
        .oneshot(request_json(
            "POST",
            "/attachments/uploads",
            &member,
            json!({ "filename": "b.png", "size": 12, "channel_id": channel.id.to_string() }),
        ))
        .await
        .unwrap();
    assert_eq!(session.status(), StatusCode::CREATED);
}
