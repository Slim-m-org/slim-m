// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A category is listed when it or one of its sub-categories holds a channel the
//! member can view, never downward; only deployment-level MANAGE_CHANNELS lists all.

use std::collections::HashSet;

use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use uuid::Uuid;

use super::world::{NONE, VIEW, entry, has, world};

/// Every listed sub-category's parent is listed too.
fn assert_parents_listed(listed: &[Value]) {
    let ids: HashSet<&str> = listed.iter().map(|c| c["id"].as_str().unwrap()).collect();
    for category in listed {
        if let Some(parent) = category["parent_id"].as_str() {
            assert!(ids.contains(parent), "{category} lists a parent it hides");
        }
    }
}

#[tokio::test]
async fn a_cs_member_without_the_gamer_role_sees_gamers_only_as_the_heading_over_cs2() {
    let w = world("slimm-nested-vis-cs").await;
    let listed = w.categories(&w.cs.token).await;
    let names = super::world::names(&listed);
    assert!(has(&names, "gamers") && has(&names, "cs2"), "{names:?}");
    assert!(!has(&names, "minecraft"), "{names:?}");
    assert_parents_listed(&listed);
    let cs2 = listed.iter().find(|c| c["name"] == "cs2").unwrap();
    assert_eq!(cs2["parent_id"], json!(w.gamers));

    let channels = w.channel_names(&w.cs.token).await;
    assert!(has(&channels, "cs-chat"), "{channels:?}");
    for hidden in ["gamers-chat", "mc-chat"] {
        assert!(!has(&channels, hidden), "{hidden} leaked: {channels:?}");
    }
}

#[tokio::test]
async fn a_gamer_member_sees_gamers_and_minecraft_and_nothing_of_cs2() {
    let w = world("slimm-nested-vis-gamer").await;
    let listed = w.categories(&w.gamer.token).await;
    let names = super::world::names(&listed);
    assert!(
        has(&names, "gamers") && has(&names, "minecraft"),
        "{names:?}"
    );
    assert_parents_listed(&listed);
    let channels = w.channel_names(&w.gamer.token).await;
    assert!(has(&channels, "gamers-chat") && has(&channels, "mc-chat"));

    for uri in ["/categories", "/channels"] {
        let raw = w.ok("GET", uri, &w.gamer.token, None).await.to_string();
        for hidden in ["cs2", "cs-chat", w.cs2.as_str(), w.cs_chat.as_str()] {
            assert!(!raw.contains(hidden), "{uri} leaked {hidden}: {raw}");
        }
    }
}

#[tokio::test]
async fn someone_with_neither_role_sees_nothing_of_gamers() {
    let w = world("slimm-nested-vis-neither").await;
    let names = w.category_names(&w.neither.token).await;
    for hidden in ["gamers", "minecraft", "cs2"] {
        assert!(!has(&names, hidden), "{hidden} leaked: {names:?}");
    }
    let channels = w.channel_names(&w.neither.token).await;
    for hidden in ["gamers-chat", "mc-chat", "cs-chat"] {
        assert!(!has(&channels, hidden), "{hidden} leaked: {channels:?}");
    }
}

#[tokio::test]
async fn a_manager_is_listed_every_category_at_both_levels_including_empty_ones() {
    let w = world("slimm-nested-vis-manager").await;
    let empty = w.create_category("empty-sub", Some(&w.gamers)).await;
    let listed = w.categories(&w.admin).await;
    let names = super::world::names(&listed);
    for name in ["gamers", "minecraft", "cs2", "empty-sub"] {
        assert!(has(&names, name), "{name} missing for a manager: {names:?}");
    }
    assert_parents_listed(&listed);
    for member in [&w.gamer, &w.cs, &w.neither] {
        let seen = w.category(&member.token, &empty).await;
        assert!(seen.is_none(), "an empty sub-category leaked: {seen:?}");
    }
}

#[tokio::test]
async fn manage_channels_on_one_channel_does_not_list_every_category() {
    let w = world("slimm-nested-vis-one-channel").await;
    let grant = Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS);
    let body = json!({"overwrites": [entry("member", &w.neither.id.to_string(), grant, NONE)]});
    let uri = format!("/channels/{}/overwrites", w.gamers_chat);
    w.ok("PUT", &uri, &w.admin, Some(body)).await;

    let names = w.category_names(&w.neither.token).await;
    assert!(
        has(&names, "gamers"),
        "they can view gamers-chat: {names:?}"
    );
    for hidden in ["minecraft", "cs2"] {
        assert!(!has(&names, hidden), "{hidden} leaked: {names:?}");
    }
}

#[tokio::test]
async fn a_visible_parent_never_names_a_sub_category_the_member_cannot_view_into() {
    let w = world("slimm-nested-vis-downward").await;
    let open = json!([entry("role", &w.everyone, VIEW, NONE)]);
    w.set_overwrites(&w.gamers, open).await;
    let names = w.category_names(&w.neither.token).await;
    assert!(
        has(&names, "gamers") && has(&names, "minecraft"),
        "{names:?}"
    );
    assert!(!has(&names, "cs2"), "cs2 is still cs-only: {names:?}");
}

#[tokio::test]
async fn a_message_in_a_hidden_sub_category_stays_out_of_search() {
    let w = world("slimm-nested-vis-search").await;
    let body = json!({"id": Uuid::now_v7().to_string(), "content": "headshot plans"});
    let uri = format!("/channels/{}/messages", w.cs_chat);
    w.ok("POST", &uri, &w.admin, Some(body)).await;

    let search = "/search/messages?q=headshot";
    let found = w.ok("GET", search, &w.cs.token, None).await.to_string();
    assert!(found.contains("headshot plans"), "{found}");
    for member in [&w.gamer, &w.neither] {
        let found = w.ok("GET", search, &member.token, None).await.to_string();
        assert!(!found.contains("headshot"), "{found}");
    }
}
