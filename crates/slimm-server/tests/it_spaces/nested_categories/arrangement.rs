// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The whole arrangement in one request, and the tree order every listing uses,
//! old clients' flat positions included.

use serde_json::json;

use super::world::{category_events, groups_of, ids, order_body, world};

#[tokio::test]
async fn reorder_files_and_unfiles_categories_in_one_request() {
    let mut w = world("slimm-nested-order").await;
    let after = w.create_category("after", None).await;
    w.drain();
    let listed = w.categories(&w.admin).await;
    let mut groups = groups_of(&listed);
    groups[0].1.retain(|id| *id != after);
    groups[0].1.push(w.minecraft.clone());
    let gamers_group = groups
        .iter_mut()
        .find(|(p, _)| *p == json!(w.gamers))
        .unwrap();
    gamers_group.1 = vec![w.cs2.clone(), after.clone()];
    let answer = w
        .ok(
            "PUT",
            "/categories/order",
            &w.admin,
            Some(order_body(&groups)),
        )
        .await;
    assert_eq!(category_events(&w.drain()), (1, 0));
    let answer = answer.as_array().unwrap();
    let find = |id: &str| answer.iter().find(|c| c["id"] == json!(id)).unwrap();
    assert_eq!(find(&after)["parent_id"], json!(w.gamers));
    assert!(find(&w.minecraft)["parent_id"].is_null());
    assert_eq!(
        &w.categories(&w.admin).await,
        answer,
        "answered in tree order"
    );
    assert_eq!(w.overwrites(&w.minecraft).await.get("synced"), None);
    assert_eq!(w.overwrites(&after).await["synced"], json!(false));
    let log = w.ok("GET", "/space/audit-log", &w.admin, None).await;
    assert_eq!(log[0]["action"], "category.reorder", "{log}");

    w.ok(
        "PUT",
        "/categories/order",
        &w.admin,
        Some(order_body(&groups)),
    )
    .await;
    assert_eq!(
        category_events(&w.drain()),
        (0, 0),
        "a no-op publishes nothing"
    );
}

#[tokio::test]
async fn listings_come_back_in_tree_order_and_ties_never_interleave() {
    let w = world("slimm-nested-tree-order").await;
    let mc_second = w.create_channel("mc-second", &w.minecraft).await;
    let cs_second = w.create_channel("cs-second", &w.cs2).await;
    for id in [&w.minecraft, &w.cs2] {
        let uri = format!("/categories/{id}");
        w.ok("PATCH", &uri, &w.admin, Some(json!({"position": 0})))
            .await;
    }
    let listed = ids(&w.categories(&w.admin).await);
    let at = |id: &str| listed.iter().position(|x| x == id).unwrap();
    let mut subs = [at(&w.minecraft), at(&w.cs2)];
    subs.sort_unstable();
    assert_eq!(subs, [at(&w.gamers) + 1, at(&w.gamers) + 2], "{listed:?}");

    let channels: Vec<String> = w
        .store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .map(|c| c.id.to_string())
        .collect();
    let at = |id: &str| channels.iter().position(|x| x == id).unwrap();
    let start = at(&w.gamers_chat);
    let mc = [at(&w.mc_chat), at(&mc_second)];
    let cs = [at(&w.cs_chat), at(&cs_second)];
    assert_eq!(mc[1], mc[0] + 1, "minecraft's channels stay together");
    assert_eq!(cs[1], cs[0] + 1, "cs2's channels stay together");
    let mut blocks = [mc[0], cs[0]];
    blocks.sort_unstable();
    assert_eq!(
        blocks,
        [start + 1, start + 3],
        "gamers' own channel comes first"
    );
}

#[tokio::test]
async fn an_old_clients_flat_patch_positions_keep_each_sibling_group_in_order() {
    let w = world("slimm-nested-old-client").await;
    let after = w.create_category("after", None).await;
    let mut flat = ids(&w.categories(&w.admin).await);
    flat.retain(|id| *id != after);
    let gamers_at = flat.iter().position(|id| *id == w.gamers).unwrap();
    flat.insert(gamers_at, after.clone());
    for (position, id) in flat.iter().enumerate() {
        let uri = format!("/categories/{id}");
        w.ok("PATCH", &uri, &w.admin, Some(json!({"position": position})))
            .await;
    }
    let listed = w.categories(&w.admin).await;
    assert_eq!(ids(&listed), flat, "the tree order is the flat order");
    let cs2 = listed.iter().find(|c| c["id"] == json!(w.cs2)).unwrap();
    assert_eq!(
        cs2["parent_id"],
        json!(w.gamers),
        "a flat PATCH never re-parents"
    );
}

#[tokio::test]
async fn one_arrangement_can_empty_a_parent_and_file_it_under_another() {
    let w = world("slimm-nested-order-swap").await;
    let other = w.create_category("other", None).await;
    let listed = w.categories(&w.admin).await;
    let mut groups = groups_of(&listed);
    groups.retain(|(parent, _)| *parent != json!(w.gamers));
    let mut top = groups.remove(0);
    top.1.retain(|id| *id != w.gamers);
    top.1.extend([w.minecraft.clone(), w.cs2.clone()]);
    groups.push((json!(other), vec![w.gamers.clone()]));
    groups.push(top);

    w.ok(
        "PUT",
        "/categories/order",
        &w.admin,
        Some(order_body(&groups)),
    )
    .await;
    let gamers = w.category(&w.admin, &w.gamers).await.unwrap();
    assert_eq!(gamers["parent_id"], json!(other));
    for sub in [&w.minecraft, &w.cs2] {
        let sub = w.category(&w.admin, sub).await.unwrap();
        assert!(sub["parent_id"].is_null(), "{sub}");
    }
}
