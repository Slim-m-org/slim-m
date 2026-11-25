// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Exporting a board: who may, and who sees the copy.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelCategoryId, ChannelId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{ChannelDefaults, OverwriteBatchEntry};

use crate::canvas_export::Rig;
use crate::canvas_export_flow::{get, live};

#[tokio::test]
async fn a_dm_and_a_personal_space_are_not_found_and_a_closed_board_is_canvas_off() {
    let rig = Rig::new().await;
    let friend = rig.store.create_user("friend", "Friend").await.unwrap().id;
    let dm = rig.store.open_dm(rig.admin, friend).await.unwrap().id;
    let personal = rig.store.open_dm(rig.admin, rig.admin).await.unwrap().id;
    let text = rig.store.create_channel("words", "text").await.unwrap().id;
    let closed = rig.store.create_channel("quiet", "voice").await.unwrap().id;

    let mut seen = Vec::new();
    for source in [dm, personal, text, closed] {
        let body = Rig::body(ChannelId::generate(), "copy");
        let (status, answer) = rig.export_from(&rig.token, source, body).await;
        seen.push((status, answer["code"].as_str().map(str::to_owned)));
    }

    let off = Some("canvas_off".to_owned());
    assert_eq!(
        seen,
        [
            (StatusCode::NOT_FOUND, None),
            (StatusCode::NOT_FOUND, None),
            (StatusCode::FORBIDDEN, off.clone()),
            (StatusCode::FORBIDDEN, off),
        ]
    );
}

#[tokio::test]
async fn without_the_bits_an_export_is_refused_before_anything_is_written() {
    let rig = Rig::new().await;
    rig.place("note", json!({ "text": "a" })).await;
    let role = rig
        .store
        .create_role("channel managers", Permissions::MANAGE_CHANNELS, false)
        .await
        .unwrap();
    let person = |name: &'static str| {
        let store = rig.store.clone();
        async move {
            let id = store.create_user(name, name).await.unwrap().id;
            let token = store.open_session(id, "cli").await.unwrap().access_token;
            (id, token)
        }
    };
    let (manager, manager_token) = person("manager").await;
    let (_, member_token) = person("plain").await;
    let (spectator, spectator_token) = person("watcher").await;
    rig.store.assign_role(manager, role).await.unwrap();
    rig.store.assign_role(spectator, role).await.unwrap();
    rig.store
        .set_member_overwrite(
            rig.source,
            spectator,
            Permissions::NONE,
            Permissions::USE_CANVAS,
        )
        .await
        .unwrap();

    let mut statuses = Vec::new();
    for (token, clear) in [
        (&member_token, false),
        (&spectator_token, false),
        (&manager_token, true),
    ] {
        let mut body = Rig::body(ChannelId::generate(), "copy");
        body["clear_source"] = json!(clear);
        statuses.push(rig.export_from(token, rig.source, body).await.0);
    }

    assert_eq!(statuses, [StatusCode::FORBIDDEN; 3]);
    let made = rig
        .scalar(
            "SELECT COUNT(*) FROM canvas_exports WHERE source_channel_id = ?",
            rig.source,
        )
        .await;
    assert_eq!((made, live(&rig, rig.source).await), (0, 1));
    let body = Rig::body(ChannelId::generate(), "copy");
    let (ok, _) = rig.export_from(&manager_token, rig.source, body).await;
    assert_eq!(
        ok,
        StatusCode::OK,
        "a manager without MANAGE_CANVAS may still copy"
    );
}

#[tokio::test]
async fn a_private_source_stays_private_and_its_rows_are_copied() {
    let rig = Rig::new().await;
    let private = rig
        .store
        .create_channel_with_id(
            ChannelId::generate(),
            "secret plans",
            "voice",
            None,
            Some(rig.admin),
            ChannelDefaults {
                canvas_enabled: true,
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .channel;
    let id = ChannelId::generate();

    let (status, body) = rig
        .export_from(&rig.token, private.id, Rig::body(id, "copy"))
        .await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(rig.store.channel_restricted(id).await.unwrap());
    let rows = |channel: ChannelId| {
        let pool = rig.pool.clone();
        async move {
            sqlx::query_as::<_, (String, Vec<u8>, i64, i64)>(
                "SELECT target_type, target_id, allow, deny FROM channel_overwrites \
                 WHERE channel_id = ? ORDER BY 1, 2",
            )
            .bind(channel)
            .fetch_all(&pool)
            .await
            .unwrap()
        }
    };
    let copied = rows(id).await;
    assert_eq!(copied, rows(private.id).await);
    assert_eq!(copied.len(), 2);
    let synced = rig
        .scalar("SELECT permissions_synced FROM channels WHERE id = ?", id)
        .await;
    assert_eq!(synced, 0);
}

#[tokio::test]
async fn a_synced_source_stays_synced_in_its_own_category_and_not_in_another() {
    let rig = Rig::new().await;
    let kept = rig.store.create_category("gamers").await.unwrap().id;
    let moved = rig.store.create_category("work").await.unwrap().id;
    let entry = OverwriteBatchEntry {
        target_type: "member",
        target_id: rig.admin.0,
        allow: Permissions::USE_CANVAS,
        deny: Permissions::NONE,
    };
    rig.store
        .set_category_overwrites(kept, &[entry])
        .await
        .unwrap();
    let source = rig
        .store
        .create_channel_with_id(
            ChannelId::generate(),
            "minecraft",
            "voice",
            Some(kept),
            None,
            ChannelDefaults {
                canvas_enabled: true,
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .channel;
    let synced = |channel: ChannelId| {
        rig.scalar(
            "SELECT permissions_synced FROM channels WHERE id = ?",
            channel,
        )
    };
    assert_eq!(synced(source.id).await, 1);

    let same = ChannelId::generate();
    let (status, body) = rig
        .export_from(&rig.token, source.id, Rig::body(same, "same"))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["channel"]["category_id"], kept.to_string());
    assert_eq!(synced(same).await, 1);

    let elsewhere = ChannelId::generate();
    let mut ask = Rig::body(elsewhere, "elsewhere");
    ask["category_id"] = json!(moved.to_string());
    let (status, body) = rig.export_from(&rig.token, source.id, ask).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["channel"]["category_id"], moved.to_string());
    assert_eq!(synced(elsewhere).await, 0);
    let rows = rig
        .scalar(
            "SELECT COUNT(*) FROM channel_overwrites WHERE channel_id = ?",
            elsewhere,
        )
        .await;
    assert_eq!(rows, 1, "the source's own rows came along");

    let mut none = Rig::body(ChannelId::generate(), "loose");
    none["category_id"] = Value::Null;
    let (_, body) = rig.export_from(&rig.token, source.id, none).await;
    assert_eq!(body["channel"]["category_id"], Value::Null);
}

#[tokio::test]
async fn an_unknown_category_is_refused_and_a_blank_name_too() {
    let rig = Rig::new().await;
    let mut ask = Rig::body(ChannelId::generate(), "copy");
    ask["category_id"] = json!(ChannelCategoryId::generate().to_string());
    let (unknown, _) = rig.export(ask).await;
    let (blank, _) = rig.export(Rig::body(ChannelId::generate(), "   ")).await;
    assert_eq!(
        (unknown, blank),
        (StatusCode::BAD_REQUEST, StatusCode::BAD_REQUEST)
    );
}

#[tokio::test]
async fn the_voice_call_toggle_the_audit_row_and_the_capability() {
    let rig = Rig::new().await;
    let mut ask = Rig::body(ChannelId::generate(), "with a call");
    ask["voice_enabled"] = json!(true);
    let (status, body) = rig.export(ask).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["channel"]["voice_enabled"], true);
    assert_eq!(body["channel"]["canvas_enabled"], true);

    let log = get(&rig, "/space/audit-log", Some(&rig.token)).await;
    assert_eq!(log[0]["action"], "channel.canvas_export");
    assert_eq!(log[0]["target_id"], rig.source.to_string());

    let version = get(&rig, "/version", None).await;
    let capabilities = version["capabilities"].as_array().unwrap();
    assert!(capabilities.contains(&json!("canvas_export")));
}

#[tokio::test]
async fn a_member_who_cannot_see_the_source_never_sees_the_copy() {
    let rig = Rig::new().await;
    let member = rig.store.create_user("nia", "Nia").await.unwrap().id;
    let token = rig
        .store
        .open_session(member, "cli")
        .await
        .unwrap()
        .access_token;
    rig.store
        .set_member_overwrite(
            rig.source,
            member,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let id = ChannelId::generate();
    rig.export(Rig::body(id, "copy")).await;

    let listed = get(&rig, "/channels", Some(&token)).await;

    let ids: Vec<&str> = listed
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|c| c["id"].as_str())
        .collect();
    assert!(!ids.contains(&id.to_string().as_str()));
    assert!(!ids.contains(&rig.source.to_string().as_str()));
}
