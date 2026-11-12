// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `has:`, `before:`/`after:`, and combining several operators at once. Each
//! reads a message's own bytes (its attachments, its content, its
//! `created_at`) rather than resolving a caller-supplied name - the
//! oracle-safety concern `operators_identity` carries does not apply here,
//! so an unrecognised `has:` value is a plain 400 instead of an empty page.

use axum::http::StatusCode;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::message_search::fixtures::*;

/// `has:attachment` narrows to messages carrying at least one.
#[tokio::test]
async fn has_attachment_filters_to_messages_carrying_one() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let channel_id = channel.id.to_string();

    let attachment_id = upload_attachment(&app, &token).await;
    send_with_attachments(
        &app,
        &channel_id,
        &token,
        "here is the photo",
        &[&attachment_id],
    )
    .await;
    send(&app, &channel_id, &token, "here is nothing").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/messages/search?q=here&has=attachment"),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["content"], "here is the photo");
}

/// `has:link` narrows to messages whose content looks like it carries a URL.
#[tokio::test]
async fn has_link_filters_to_messages_containing_a_url() {
    let (store, _guard) = new_store().await;
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

    send(&app, &channel_id, &token, "see https://example.com/cats").await;
    send(&app, &channel_id, &token, "see my new haircut").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/messages/search?q=see&has=link"),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["content"], "see https://example.com/cats");
}

/// An unrecognised `has:` value is a 400, not a silent no-op.
#[tokio::test]
async fn has_rejects_an_unknown_value() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{}/messages/search?q=x&has=gif", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// `before:`/`after:` bound a search to a calendar day, UTC, with `before`
/// excluding the named day itself and `after` including it. `recent` sits
/// exactly on the boundary millisecond rather than merely somewhere later
/// that day, so this actually distinguishes `<` from `<=` and `>=` from `>`
/// rather than passing either way.
#[tokio::test]
async fn before_and_after_date_bound_by_calendar_day() {
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

    let old = send(&app, &channel_id, &token, "timelines never lie").await;
    let recent = send(&app, &channel_id, &token, "timelines still don't lie").await;

    // 2024-01-01T00:00:00Z, well before any test run's real clock.
    set_created_at(&pool, old["id"].as_str().unwrap(), 1_704_067_200_000).await;
    // 2024-06-15T00:00:00Z, the boundary millisecond itself; see this fn's own doc.
    set_created_at(&pool, recent["id"].as_str().unwrap(), 1_718_409_600_000).await;

    let before = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!(
                    "/channels/{channel_id}/messages/search?q=timelines&before_date=2024-06-15"
                ),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let before = before.as_array().unwrap();
    assert_eq!(before.len(), 1, "before excludes the named day itself");
    assert_eq!(before[0]["content"], "timelines never lie");

    let after = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!(
                    "/channels/{channel_id}/messages/search?q=timelines&after_date=2024-06-15"
                ),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let after = after.as_array().unwrap();
    assert_eq!(after.len(), 1, "after includes the named day itself");
    assert_eq!(after[0]["content"], "timelines still don't lie");
}

/// A malformed `before_date`/`after_date` is a 400, not a silent no-op or a
/// panic on a hand-rolled date parse.
#[tokio::test]
async fn a_malformed_date_is_a_bad_request() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!(
                "/channels/{}/messages/search?q=x&before_date=not-a-date",
                channel.id
            ),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// Several operators together narrow a search further than any one alone,
/// combining with the free text rather than overriding it.
#[tokio::test]
async fn combined_operators_narrow_together() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let channel_id = channel.id.to_string();

    let attachment_id = upload_attachment(&app, &alice).await;
    // Matches every operator below.
    send_with_attachments(
        &app,
        &channel_id,
        &alice,
        "roadmap draft attached",
        &[&attachment_id],
    )
    .await;
    // Wrong author.
    send(&app, &channel_id, &bob, "roadmap draft, no file though").await;
    // Right author, no attachment.
    send(&app, &channel_id, &alice, "roadmap notes, nothing attached").await;
    // Right author, has an attachment, wrong words.
    let other_attachment = upload_attachment(&app, &alice).await;
    send_with_attachments(
        &app,
        &channel_id,
        &alice,
        "unrelated photo",
        &[&other_attachment],
    )
    .await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!(
                    "/channels/{channel_id}/messages/search?q=roadmap&from=alice&has=attachment"
                ),
                Some(&alice),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["content"], "roadmap draft attached");
}
