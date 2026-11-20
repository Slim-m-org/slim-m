// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `after_ms`/`before_ms`: the date bounds as instants, so a client can send
//! the searcher's own local midnights instead of a UTC calendar day.

use serde_json::Value;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::message_search::fixtures::*;

/// 2024-06-15T00:00:00Z.
const JUNE_15: i64 = 1_718_409_600_000;
const HOUR: i64 = 3_600_000;

#[tokio::test]
async fn instants_bound_by_the_millisecond_and_the_tighter_bound_wins() {
    let (store, pool, _guard) = new_store_with_pool().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let channel_id = channel.id.to_string();

    // Tokyo's June 15 starts at 15:00 UTC on June 14: these sit either side of it.
    let tokyo_midnight = JUNE_15 - 9 * HOUR;
    for (content, at) in [
        ("moments late on the 14th", tokyo_midnight - 1),
        ("moments on the 15th", tokyo_midnight),
        ("moments in the afternoon", JUNE_15 + 6 * HOUR),
    ] {
        let sent = send(&app, &channel_id, &token, content).await;
        set_created_at(&pool, sent["id"].as_str().unwrap(), at).await;
    }

    let found = |query: String| {
        let app = app.clone();
        let token = token.clone();
        let uri = format!("/channels/{channel_id}/messages/search?q=moments&{query}");
        async move {
            let response = app
                .oneshot(request("GET", &uri, Some(&token), None))
                .await
                .unwrap();
            let body: Value = json_body(response).await;
            let mut out: Vec<String> = body
                .as_array()
                .unwrap_or_else(|| panic!("{uri}: {body}"))
                .iter()
                .map(|m| m["content"].as_str().unwrap().to_owned())
                .collect();
            out.sort();
            out
        }
    };

    let day = format!(
        "after_ms={tokyo_midnight}&before_ms={}",
        tokyo_midnight + 24 * HOUR
    );
    assert_eq!(
        found(day).await,
        ["moments in the afternoon", "moments on the 15th"],
        "a local day is its own 24 hours, not the UTC calendar day"
    );
    let both = format!("after_ms={tokyo_midnight}&after_date=2024-06-15");
    assert_eq!(
        found(both).await,
        ["moments in the afternoon"],
        "given both ways, the later start holds"
    );
    let far = format!("after_ms={tokyo_midnight}&before_ms=253402300800000");
    assert_eq!(found(far).await.len(), 2, "a bound past year 9999 is fine");
}
