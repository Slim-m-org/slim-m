// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Paging a search across channels with `before_id` returns every hit once,
//! including two messages in different channels at the same instant
//! (issue 1811).

use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::fixtures::*;

#[tokio::test]
async fn paging_across_channels_neither_skips_nor_repeats() {
    let (store, pool, _guard) = new_store_with_pool().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let alpha = store
        .create_channel("alpha", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let bravo = store
        .create_channel("bravo", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let mut sent = Vec::new();
    for (channel, at) in [
        (&alpha, 100),
        (&bravo, 200),
        (&alpha, 300),
        (&bravo, 300),
        (&alpha, 400),
    ] {
        let id = send(&app, channel, &token, "otters").await["id"]
            .as_str()
            .unwrap()
            .to_owned();
        set_created_at(&pool, &id, at).await;
        sent.push(id);
    }

    let mut seen: Vec<String> = Vec::new();
    let mut cursor = String::new();
    for _ in 0..10 {
        let page = json_body(
            app.clone()
                .oneshot(request(
                    "GET",
                    &format!("/search/messages?q=otters&limit=2{cursor}"),
                    Some(&token),
                    None,
                ))
                .await
                .unwrap(),
        )
        .await;
        let ids: Vec<String> = page
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap().to_owned())
            .collect();
        let Some(last) = ids.last() else { break };
        cursor = format!("&before_id={last}");
        seen.extend(ids);
    }

    let mut unique = seen.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), seen.len(), "a hit came back twice: {seen:?}");
    sent.sort();
    assert_eq!(unique, sent, "a hit was skipped");
}

#[tokio::test]
async fn an_unknown_cursor_is_refused_and_before_is_ignored_beside_before_id() {
    let (store, pool, _guard) = new_store_with_pool().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let alpha = store
        .create_channel("alpha", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let mut ids = Vec::new();
    for at in [100, 200, 300] {
        let id = send(&app, &alpha, &token, "herons").await["id"]
            .as_str()
            .unwrap()
            .to_owned();
        set_created_at(&pool, &id, at).await;
        ids.push(id);
    }
    let get = |uri: String| {
        let app = app.clone();
        let token = token.clone();
        async move {
            app.oneshot(request("GET", &uri, Some(&token), None))
                .await
                .unwrap()
        }
    };

    let unknown = get(format!(
        "/search/messages?q=herons&before_id={}",
        uuid::Uuid::now_v7()
    ))
    .await;
    assert_eq!(unknown.status(), axum::http::StatusCode::BAD_REQUEST);

    let page = json_body(
        get(format!(
            "/search/messages?q=herons&before=1&before_id={}",
            ids[2]
        ))
        .await,
    )
    .await;
    assert_eq!(
        page.as_array().unwrap().len(),
        2,
        "before=1 should not narrow a before_id page"
    );
}
