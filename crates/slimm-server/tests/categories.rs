// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel categories: the MANAGE_CHANNELS gate, create/rename/reposition,
//! and that deleting a category never deletes its channels. See
//! docs/decisions/0006-channel-categories.md.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token as register, request};

#[tokio::test]
async fn manager_can_create_rename_and_reposition_a_category() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/categories",
                Some(&token),
                Some(json!({ "name": "extras" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(created["name"], "extras");
    let category_id = created["id"].as_str().unwrap().to_owned();

    let updated = json_body(
        app.clone()
            .oneshot(request(
                "PATCH",
                &format!("/categories/{category_id}"),
                Some(&token),
                Some(json!({ "name": "renamed", "position": 5 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(updated["name"], "renamed");
    assert_eq!(updated["position"].as_i64().unwrap(), 5);
}

#[tokio::test]
async fn creating_a_category_without_manage_channels_is_forbidden() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/categories",
            Some(&token),
            Some(json!({ "name": "extras" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// An update naming neither field is a 400, the same convention
/// `updateChannel` follows.
#[tokio::test]
async fn updating_a_category_with_nothing_to_change_is_bad_request() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let category = store.create_category("extras").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/categories/{}", category.id),
            Some(&token),
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// Deleting a category never deletes the channels filed under it - they fall
/// back to uncategorised, the load-bearing property the decision record
/// names as the reason this cannot be a cascading foreign key.
#[tokio::test]
async fn deleting_a_category_keeps_its_channels_and_uncategorises_them() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let category = store.create_category("extras").await.unwrap();
    let channel = store.create_channel("a", "text").await.unwrap();
    store
        .reorder_channels(&[slimm_server::store::ChannelOrderGroup {
            category_id: Some(category.id),
            channel_ids: vec![channel.id],
        }])
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/categories/{}", category.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let still_there = store
        .channel(channel.id)
        .await
        .unwrap()
        .expect("the channel must not have been deleted along with its category");
    assert_eq!(
        still_there.category_id, None,
        "an orphaned channel falls back to uncategorised"
    );

    // Idempotent: deleting it again is still a 204, not a 404.
    let again = app
        .oneshot(request(
            "DELETE",
            &format!("/categories/{}", category.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(again.status(), StatusCode::NO_CONTENT);
}

/// The last-channel delete guard is unaffected by category placement:
/// spreading channels across categories must not let a deployment be talked
/// down to zero live channels, since categories decide placement only.
#[tokio::test]
async fn the_last_channel_guard_is_unaffected_by_categories() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let voice_cat = store.create_category("Voice").await.unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let b = store.create_channel("b", "voice").await.unwrap();
    store
        .reorder_channels(&[
            slimm_server::store::ChannelOrderGroup {
                category_id: None,
                channel_ids: vec![a.id],
            },
            slimm_server::store::ChannelOrderGroup {
                category_id: Some(voice_cat.id),
                channel_ids: vec![b.id],
            },
        ])
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let first = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", a.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::NO_CONTENT);

    let refused = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", b.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        refused.status(),
        StatusCode::CONFLICT,
        "the last live channel is refused however its category is arranged"
    );
}

/// Creating straight into a category, rather than creating uncategorised and
/// following up with a reorder - two calls whose second can fail on its own
/// and leave the channel in a section nobody chose.
#[tokio::test]
async fn a_channel_can_be_created_directly_into_a_category() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let category = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/categories",
                Some(&token),
                Some(json!({ "name": "extras" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let category_id = category["id"].as_str().unwrap().to_owned();

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "name": "notes", "category_id": category_id })),
            ))
            .await
            .unwrap(),
    )
    .await;

    assert_eq!(created["name"], "notes");
    assert_eq!(created["category_id"], category_id);
}

/// Refused rather than filed as uncategorised: a client that asked for a
/// specific section and silently got a different one is worse than an error
/// it can show.
#[tokio::test]
async fn creating_into_a_category_that_does_not_exist_is_refused() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            Some(&token),
            Some(json!({
                "name": "notes",
                "category_id": uuid::Uuid::now_v7().to_string(),
            })),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let channels = store.list_channels().await.unwrap();
    assert!(
        !channels.iter().any(|c| c.name == "notes"),
        "the refused create must not have left a channel behind"
    );
}

/// Absent means uncategorised, which is the ordinary create and must stay
/// exactly as it was.
#[tokio::test]
async fn creating_without_a_category_still_lands_uncategorised() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "name": "notes" })),
            ))
            .await
            .unwrap(),
    )
    .await;

    assert!(created["category_id"].is_null());
}

/// Deleting a category nulls `category_id` on every channel in it, so filing
/// a new one under that same id would resurrect exactly the dangling
/// reference the delete cleaned up - and the rail draws channels by grouping
/// under a live category, so the channel would simply not appear.
#[tokio::test]
async fn a_deleted_category_cannot_be_created_into() {
    let (store, _guard) = support::new_store("slimm-categories-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let category = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/categories",
                Some(&token),
                Some(json!({ "name": "doomed" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let category_id = category["id"].as_str().unwrap().to_owned();

    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/categories/{category_id}"),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            Some(&token),
            Some(json!({ "name": "orphan", "category_id": category_id })),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let channels = store.list_channels().await.unwrap();
    assert!(
        !channels.iter().any(|c| c.name == "orphan"),
        "a channel filed under a dead category would vanish from the rail"
    );
}
