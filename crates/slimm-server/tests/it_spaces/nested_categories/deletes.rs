// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting a category moves what it holds up one level and changes nobody's view.

use serde_json::{Value, json};

use super::world::{category_events, has, ids, world};

#[tokio::test]
async fn deleting_a_parent_moves_its_sub_categories_into_its_slot() {
    let mut w = world("slimm-nested-delete-parent").await;
    let after = w.create_category("after", None).await;
    let before: Vec<String> = ids(&w.categories(&w.admin).await);
    let minecraft_rows = w.overwrites(&w.minecraft).await["overwrites"].clone();
    let cs2_rows = w.overwrites(&w.cs2).await["overwrites"].clone();
    w.drain();

    let uri = format!("/categories/{}", w.gamers);
    w.ok("DELETE", &uri, &w.admin, None).await;
    assert_eq!(category_events(&w.drain()), (1, 0), "one category.changed");

    let listed = w.categories(&w.admin).await;
    let expected: Vec<String> = before.into_iter().filter(|id| *id != w.gamers).collect();
    assert_eq!(ids(&listed), expected, "the sub-categories took its slot");
    let top: Vec<&Value> = listed.iter().filter(|c| c["parent_id"].is_null()).collect();
    assert_eq!(top.len(), listed.len(), "every category is top-level now");
    let positions: Vec<i64> = top
        .iter()
        .map(|c| c["position"].as_i64().unwrap())
        .collect();
    assert!(positions.windows(2).all(|p| p[0] < p[1]), "{positions:?}");
    assert_eq!(ids(&listed).last(), Some(&after));

    let minecraft = w.overwrites(&w.minecraft).await;
    assert!(
        minecraft.get("synced").is_none(),
        "top-level now: {minecraft}"
    );
    assert_eq!(minecraft["overwrites"], minecraft_rows, "kept its rows");
    assert_eq!(w.overwrites(&w.cs2).await["overwrites"], cs2_rows);

    let channels = w.store.list_channels().await.unwrap();
    let find = |id: &str| channels.iter().find(|c| c.id.to_string() == id).unwrap();
    assert!(
        find(&w.gamers_chat).category_id.is_none(),
        "own channels fall to uncategorised"
    );
    assert_eq!(
        find(&w.mc_chat).category_id.unwrap().to_string(),
        w.minecraft
    );
    let synced = format!("/channels/{}/overwrites", w.mc_chat);
    assert_eq!(
        w.ok("GET", &synced, &w.admin, None).await["synced"],
        json!(true)
    );

    let gamer = w.channel_names(&w.gamer.token).await;
    assert!(has(&gamer, "gamers-chat") && has(&gamer, "mc-chat") && !has(&gamer, "cs-chat"));
    let neither = w.channel_names(&w.neither.token).await;
    assert!(!has(&neither, "gamers-chat") && !has(&neither, "mc-chat"));
}

#[tokio::test]
async fn deleting_a_sub_category_moves_its_channels_to_the_end_of_its_parent() {
    let mut w = world("slimm-nested-delete-sub").await;
    let second = w.create_channel("cs-second", &w.cs2).await;
    w.drain();
    let uri = format!("/categories/{}", w.cs2);
    w.ok("DELETE", &uri, &w.admin, None).await;
    assert_eq!(category_events(&w.drain()), (1, 0));

    let in_gamers: Vec<String> = w
        .store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .filter(|c| c.category_id.map(|id| id.to_string()) == Some(w.gamers.clone()))
        .map(|c| c.id.to_string())
        .collect();
    assert_eq!(
        in_gamers,
        vec![w.gamers_chat.clone(), w.cs_chat.clone(), second]
    );
    let state = format!("/channels/{}/overwrites", w.cs_chat);
    assert_eq!(
        w.ok("GET", &state, &w.admin, None).await["synced"],
        json!(false)
    );
    assert!(
        has(&w.channel_names(&w.cs.token).await, "cs-chat"),
        "kept its rows"
    );
    assert!(!has(&w.channel_names(&w.gamer.token).await, "cs-chat"));
    assert!(w.category(&w.admin, &w.cs2).await.is_none());
}
