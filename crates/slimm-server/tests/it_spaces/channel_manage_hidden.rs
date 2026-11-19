// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! MANAGE_CHANNELS reaches only the channels its holder can see: renaming or
//! deleting a hidden one answers exactly like one that does not exist, so the
//! answer neither changes it nor hands back its name and topic.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use slimm_server::ids::ChannelId;
use support::app::{TestApp, register_account};

/// A deployment whose `member` holds MANAGE_CHANNELS, and a private channel they cannot see.
async fn with_a_hidden_channel(prefix: &str) -> (TestApp, String) {
    let app = TestApp::start(prefix).await;
    let role = app
        .create_role("builders", Permissions::MANAGE_CHANNELS.bits())
        .await;
    let grant = format!("/members/{}/roles/{role}", app.member.id);
    let (status, body) = app.call("PUT", &grant, &app.admin.token, None).await;
    assert!(status.is_success(), "grant: {status} {body}");

    let private = json!({"name": "staff", "restricted": true});
    let (status, channel) = app
        .call("POST", "/channels", &app.admin.token, Some(private))
        .await;
    assert!(status.is_success(), "{status} {channel}");
    let id = channel["id"].as_str().unwrap().to_owned();
    let topic = json!({"topic": "who we are letting go"});
    let (status, _) = app
        .call(
            "PATCH",
            &format!("/channels/{id}"),
            &app.admin.token,
            Some(topic),
        )
        .await;
    assert!(status.is_success());
    (app, id)
}

async fn admin_sees(app: &TestApp, id: &str) -> Value {
    let (_, channels) = app.call("GET", "/channels", &app.admin.token, None).await;
    let found = channels.as_array().unwrap().iter().find(|c| c["id"] == id);
    found.cloned().unwrap_or(Value::Null)
}

#[tokio::test]
async fn a_manager_cannot_rename_or_read_back_a_channel_they_cannot_see() {
    let (app, hidden) = with_a_hidden_channel("slimm-channel-manage-hidden-patch").await;
    let nowhere = uuid::Uuid::now_v7();
    let manager = &app.member.token;

    for patch in [json!({"name": "mine"}), json!({"slow_mode_seconds": 0})] {
        let refused = app
            .call(
                "PATCH",
                &format!("/channels/{hidden}"),
                manager,
                Some(patch.clone()),
            )
            .await;
        let unknown = app
            .call(
                "PATCH",
                &format!("/channels/{nowhere}"),
                manager,
                Some(patch),
            )
            .await;
        assert_eq!(refused.0, StatusCode::NOT_FOUND, "{}", refused.1);
        assert_eq!(refused, unknown, "a hidden channel answers like no channel");
    }
    let kept = admin_sees(&app, &hidden).await;
    assert_eq!(kept["name"], "staff");
    assert_eq!(kept["topic"], "who we are letting go");
}

#[tokio::test]
async fn a_manager_cannot_delete_a_channel_they_cannot_see() {
    let (app, hidden) = with_a_hidden_channel("slimm-channel-manage-hidden-delete").await;
    let nowhere = uuid::Uuid::now_v7();
    let manager = &app.member.token;

    let refused = app
        .call("DELETE", &format!("/channels/{hidden}"), manager, None)
        .await;
    let unknown = app
        .call("DELETE", &format!("/channels/{nowhere}"), manager, None)
        .await;
    assert_eq!(refused.0, StatusCode::NOT_FOUND, "{}", refused.1);
    assert_eq!(refused, unknown, "a hidden channel answers like no channel");
    assert_eq!(admin_sees(&app, &hidden).await["name"], "staff");
}

#[tokio::test]
async fn a_manager_still_renames_and_deletes_what_they_can_see() {
    let (app, hidden) = with_a_hidden_channel("slimm-channel-manage-hidden-visible").await;
    let open = app.create_channel("lounge").await;
    let manager = &app.member.token;
    let uri = format!("/channels/{open}");

    let (status, body) = app
        .call("PATCH", &uri, manager, Some(json!({"name": "den"})))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["name"], "den");
    for attempt in ["the delete", "its retry"] {
        let (status, _) = app.call("DELETE", &uri, manager, None).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{attempt}");
    }

    let admin = &app.admin.token;
    let uri = format!("/channels/{hidden}");
    for attempt in ["the delete", "its retry"] {
        let (status, _) = app.call("DELETE", &uri, admin, None).await;
        assert_eq!(
            status,
            StatusCode::NO_CONTENT,
            "an administrator's {attempt}"
        );
    }
}

#[tokio::test]
async fn nobody_manages_a_direct_message_as_a_channel() {
    let (app, _) = with_a_hidden_channel("slimm-channel-manage-hidden-dm").await;
    let carol = register_account(&app.store, "carol").await;
    let open = format!("/dms/{}", carol.id);
    let (_, dm) = app.call("POST", &open, &app.member.token, None).await;
    let dm = dm["channel_id"].as_str().expect("a direct message");
    let uri = format!("/channels/{dm}");
    let nowhere = format!("/channels/{}", uuid::Uuid::now_v7());

    // The store refuses a direct message's row; the voice-only patch used to answer for it first.
    let patches = [
        json!({"name": "ours now", "topic": "read", "slow_mode_seconds": 60}),
        json!({"join_muted": true}),
    ];
    for (who, account) in [("an outside admin", &app.admin), ("a party", &app.member)] {
        for patch in &patches {
            let token = &account.token;
            let refused = app.call("PATCH", &uri, token, Some(patch.clone())).await;
            let unknown = app
                .call("PATCH", &nowhere, token, Some(patch.clone()))
                .await;
            assert_eq!(refused.0, StatusCode::NOT_FOUND, "{who}: {}", refused.1);
            assert_eq!(refused, unknown, "{who}");
        }
    }
    let id = ChannelId(dm.parse().unwrap());
    let kept = app.store.channel(id).await.unwrap().expect("the dm");
    assert_eq!(
        (kept.name.as_str(), kept.topic, kept.slow_mode_seconds),
        ("", None, 0)
    );
}
