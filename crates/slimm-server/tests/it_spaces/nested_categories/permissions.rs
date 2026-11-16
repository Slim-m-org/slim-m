// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A parent save reaches synced sub-categories and their synced channels, stops at
//! an unsynced one, and publishes `OverwriteChanged` for exactly what it touched.

use std::collections::BTreeMap;

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::hub::Event;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;

use super::world::{NONE, VIEW, World, entry, has, world};

/// Each `OverwriteChanged` published since the last drain, by channel id.
fn overwrite_events(w: &mut World) -> BTreeMap<String, Vec<UserId>> {
    let mut out = BTreeMap::new();
    for event in w.drain() {
        if let Event::OverwriteChanged {
            channel_id,
            previously_visible_to,
        } = event
        {
            let first = out.insert(channel_id.to_string(), (*previously_visible_to).clone());
            assert!(first.is_none(), "{channel_id} was published twice");
        }
    }
    out
}

fn keys(events: &BTreeMap<String, Vec<UserId>>) -> Vec<String> {
    events.keys().cloned().collect()
}

fn sorted(ids: &[&String]) -> Vec<String> {
    let mut ids: Vec<String> = ids.iter().map(|id| (*id).clone()).collect();
    ids.sort();
    ids
}

#[tokio::test]
async fn a_parent_save_reaches_synced_sub_categories_and_stops_at_an_unsynced_one() {
    let mut w = world("slimm-nested-cascade").await;
    let cs2_before = w.overwrites(&w.cs2).await;

    let lock_out = json!([entry("role", &w.gamer_role, NONE, NONE)]);
    w.set_overwrites(&w.gamers, lock_out).await;
    let events = overwrite_events(&mut w);
    assert_eq!(keys(&events), sorted(&[&w.gamers_chat, &w.mc_chat]));
    for channel in [&w.gamers_chat, &w.mc_chat] {
        assert_eq!(
            events[channel.as_str()],
            vec![w.gamer.id],
            "the gamer could see it before"
        );
    }
    let gamer = w.channel_names(&w.gamer.token).await;
    assert!(
        !has(&gamer, "gamers-chat") && !has(&gamer, "mc-chat"),
        "{gamer:?}"
    );
    assert_eq!(w.overwrites(&w.minecraft).await["synced"], json!(true));
    assert_eq!(w.overwrites(&w.cs2).await, cs2_before, "cs2 keeps its own");
    assert!(has(&w.channel_names(&w.cs.token).await, "cs-chat"));

    let open = json!([entry("role", &w.gamer_role, VIEW, NONE)]);
    w.set_overwrites(&w.gamers, open).await;
    let events = overwrite_events(&mut w);
    assert_eq!(keys(&events), sorted(&[&w.gamers_chat, &w.mc_chat]));
    assert!(
        events.values().all(Vec::is_empty),
        "nobody could see them before"
    );
    assert!(has(&w.channel_names(&w.gamer.token).await, "mc-chat"));
    assert!(!has(&w.channel_names(&w.gamer.token).await, "cs-chat"));
}

#[tokio::test]
async fn a_sub_category_save_unsyncs_it_and_sync_brings_back_the_parents_rows() {
    let mut w = world("slimm-nested-sub-sync").await;
    let neither = w.neither.id.to_string();
    let let_in = json!([entry("member", &neither, VIEW, NONE)]);
    let saved = w.set_overwrites(&w.minecraft, let_in).await;
    assert_eq!(
        saved["synced"],
        json!(false),
        "its own save stops following"
    );
    assert_eq!(keys(&overwrite_events(&mut w)), vec![w.mc_chat.clone()]);
    assert!(has(&w.channel_names(&w.neither.token).await, "mc-chat"));

    let tighten = json!([entry("role", &w.gamer_role, VIEW, NONE)]);
    w.set_overwrites(&w.gamers, tighten).await;
    assert_eq!(keys(&overwrite_events(&mut w)), vec![w.gamers_chat.clone()]);
    assert!(
        has(&w.channel_names(&w.neither.token).await, "mc-chat"),
        "unsynced, untouched"
    );

    let uri = format!("/categories/{}/overwrites/sync", w.minecraft);
    let synced = w.ok("POST", &uri, &w.admin, None).await;
    assert_eq!(synced["synced"], json!(true));
    assert_eq!(
        synced["overwrites"],
        w.overwrites(&w.gamers).await["overwrites"]
    );
    let events = overwrite_events(&mut w);
    assert_eq!(keys(&events), vec![w.mc_chat.clone()]);
    assert!(
        events[w.mc_chat.as_str()].contains(&w.neither.id),
        "{events:?}"
    );
    assert!(!has(&w.channel_names(&w.neither.token).await, "mc-chat"));
}

#[tokio::test]
async fn syncing_a_sub_category_needs_every_bit_its_parent_allows() {
    let w = world("slimm-nested-sync-escalation").await;
    let grant = VIEW.union(Permissions::MANAGE_MESSAGES);
    w.set_overwrites(
        &w.gamers,
        json!([entry("role", &w.gamer_role, grant, NONE)]),
    )
    .await;
    let manager_role = w
        .store
        .create_role("role-manager", Permissions::MANAGE_ROLES, false)
        .await
        .unwrap();
    w.store
        .assign_role(w.neither.id, manager_role)
        .await
        .unwrap();

    let uri = format!("/categories/{}/overwrites/sync", w.cs2);
    let (status, body) = w.call("POST", &uri, &w.neither.token, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(w.overwrites(&w.cs2).await["synced"], json!(false));
    let (status, _) = w.call("POST", &uri, &w.cs.token, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "not a role manager");

    let top = format!("/categories/{}/overwrites/sync", w.gamers);
    assert_eq!(
        w.call("POST", &top, &w.admin, None).await.0,
        StatusCode::CONFLICT
    );
    let missing = format!("/categories/{}/overwrites/sync", uuid::Uuid::now_v7());
    assert_eq!(
        w.call("POST", &missing, &w.admin, None).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(w.call("POST", &uri, &w.admin, None).await.0, StatusCode::OK);
    let log = w.ok("GET", "/space/audit-log", &w.admin, None).await;
    assert_eq!(log[0]["action"], "category.overwrites_sync", "{log}");
    assert_eq!(log[0]["target_id"], json!(w.cs2));
}

#[tokio::test]
async fn a_new_sub_category_starts_with_its_parents_rows() {
    let mut w = world("slimm-nested-new-sub").await;
    let valorant = w.create_category("valorant", Some(&w.gamers)).await;
    assert!(
        overwrite_events(&mut w).is_empty(),
        "creating one changes nobody's view"
    );
    let rows = w.overwrites(&valorant).await;
    assert_eq!(rows["synced"], json!(true));
    assert_eq!(
        rows["overwrites"],
        w.overwrites(&w.gamers).await["overwrites"]
    );
    assert!(w.overwrites(&w.gamers).await.get("synced").is_none());

    w.create_channel("val-chat", &valorant).await;
    assert!(has(&w.channel_names(&w.gamer.token).await, "val-chat"));
    assert!(!has(&w.channel_names(&w.neither.token).await, "val-chat"));
    assert!(!has(&w.channel_names(&w.cs.token).await, "val-chat"));
}

#[tokio::test]
async fn syncing_a_sub_category_cannot_drop_a_deny_the_caller_could_not_lift() {
    let w = world("slimm-nested-sync-deny").await;
    let keep_quiet = json!([entry("role", &w.cs_role, VIEW, Permissions::SEND_MESSAGES)]);
    w.set_overwrites(&w.cs2, keep_quiet).await;
    let muted = Permissions::MANAGE_ROLES.union(VIEW);
    let manager_role = w
        .store
        .create_role("role-manager", muted, false)
        .await
        .unwrap();
    w.store
        .assign_role(w.neither.id, manager_role)
        .await
        .unwrap();
    let everyone = format!("/roles/{}", w.everyone);
    let view_only = json!({"permissions": VIEW.bits()});
    w.ok("PATCH", &everyone, &w.admin, Some(view_only)).await;

    let uri = format!("/categories/{}/overwrites/sync", w.cs2);
    let (status, body) = w.call("POST", &uri, &w.neither.token, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(w.overwrites(&w.cs2).await["synced"], json!(false));
}
