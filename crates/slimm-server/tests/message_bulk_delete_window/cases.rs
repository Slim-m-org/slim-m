// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `bulk-delete-by-author`: selecting a raider's messages by author and time
//! window instead of naming ids.
//!
//! The two predicates that matter are the author filter and the window
//! bound, so most cases here exist to prove each one independently: a
//! message from the right author but the wrong time survives, and a message
//! at the right time from the wrong author survives too. Everything else -
//! the audit row, the cap, the permission gate - is the same machinery
//! `message_bulk_delete`'s own suite already covers for the id-list route,
//! reused rather than re-derived; this file only proves the window-select
//! path reaches it correctly.

use axum::http::StatusCode;
use slimm_server::permissions::Permissions;
use slimm_server::store::RoleChanges;

use crate::harness::{
    app, audit, backdate, bulk_delete_by_author, channel_id, live_count, new_store, now_ms, ops,
    people, send, send_many,
};

#[tokio::test]
async fn a_moderator_deletes_an_authors_messages_inside_the_window() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    send(&app, &channel, &member.0, "spam one").await;
    send(&app, &channel, &member.0, "spam two").await;

    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(live_count(&store, &channel).await, 0);
    assert_eq!(
        ops(&pool, &channel)
            .await
            .iter()
            .filter(|(_, kind)| kind == "delete")
            .count(),
        2,
        "one delete op per message, not one per batch"
    );
}

/// The window bound's own test: a message from the named author that predates
/// the window must survive, or the bound is decorative.
#[tokio::test]
async fn a_message_outside_the_window_survives() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let old = send(&app, &channel, &member.0, "old spam").await;
    backdate(&pool, &old, now_ms() - 30 * 60_000).await;
    send(&app, &channel, &member.0, "fresh spam").await;

    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(
        live_count(&store, &channel).await,
        1,
        "the message older than the window must survive"
    );
}

/// The author filter's own test: a message inside the window but from a
/// different author must survive, or the filter is decorative.
#[tokio::test]
async fn a_different_authors_message_in_the_same_window_survives() {
    let (store, _pool, _guard) = new_store().await;
    let (admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    send(&app, &channel, &member.0, "spam").await;
    send(&app, &channel, &admin.0, "not the named author").await;

    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(
        live_count(&store, &channel).await,
        1,
        "the other author's message in the same window must survive"
    );
}

#[tokio::test]
async fn the_act_is_recorded_against_the_named_author() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    send(&app, &channel, &member.0, "spam one").await;
    send(&app, &channel, &member.0, "spam two").await;
    bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 15).await;

    let rows = audit(&pool).await;
    assert_eq!(
        rows,
        vec![(
            "messages_deleted".to_owned(),
            Some(moderator.1.0.as_bytes().to_vec()),
            Some(member.1.0.as_bytes().to_vec()),
        )],
        "one row for the one author, naming who acted and who it was about"
    );
}

/// A window matching nothing is not an error, and writes no act - the same
/// idempotence the id-list route keeps for an already-deleted id.
#[tokio::test]
async fn a_window_matching_nothing_is_a_no_op_not_an_error() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(audit(&pool).await.is_empty(), "no messages deleted, no act");
}

/// The other side of the cap boundary: exactly `MAX_BULK_DELETE_IDS` (64) must
/// succeed rather than be refused as if it were over it.
#[tokio::test]
async fn exactly_the_cap_succeeds() {
    let (store, _pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    send_many(&store, &channel, member.1, 64).await;
    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(live_count(&store, &channel).await, 0);
}

/// Over the cap must refuse the whole request, never delete the first 64 and
/// leave the rest.
#[tokio::test]
async fn more_matches_than_the_cap_refuses_rather_than_truncates() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    send_many(&store, &channel, member.1, 65).await;
    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        live_count(&store, &channel).await,
        65,
        "a refusal must not delete any of the matches, not even the first 64"
    );
    assert!(audit(&pool).await.is_empty(), "a refusal is not an act");
}

#[tokio::test]
async fn window_minutes_of_zero_is_refused() {
    let (store, _pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 0).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_window_over_a_day_is_refused() {
    let (store, _pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &member.1.0.to_string(), 1441).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// MANAGE_MESSAGES reaches an administrator's messages too, the same reach
/// the id-list route has and deliberately not a ranked one - see decision
/// 0016. This pins that the window route did not reintroduce a guard.
#[tokio::test]
async fn manage_messages_reaches_an_administrators_message_too() {
    let (store, _pool, _guard) = new_store().await;
    let (admin, moderator, _member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    send(&app, &channel, &admin.0, "an administrator speaking").await;

    let status =
        bulk_delete_by_author(&app, &channel, &moderator.0, &admin.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(live_count(&store, &channel).await, 0);
}

/// A member without MANAGE_MESSAGES cannot use this route at all, including
/// against their own messages: this is the moderation verb, and the single
/// delete is still there for an author deleting their own.
#[tokio::test]
async fn needs_manage_messages_even_for_your_own_messages() {
    let (store, _pool, _guard) = new_store().await;
    let (_admin, _moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    send(&app, &channel, &member.0, "my own message").await;
    let status =
        bulk_delete_by_author(&app, &channel, &member.0, &member.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(live_count(&store, &channel).await, 1);
}

/// A caller who cannot see the channel is refused before the route ever looks
/// for messages, so its answer cannot be used to learn a channel exists -
/// decision 0011's masking rule, the same the id-list route keeps.
#[tokio::test]
async fn a_caller_who_cannot_see_the_channel_is_refused() {
    let (store, _pool, _guard) = new_store().await;
    let (_admin, _moderator, outsider) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let everyone = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap();
    store
        .update_role(
            everyone.id,
            RoleChanges {
                permissions: Some(Permissions::NONE),
                ..RoleChanges::default()
            },
        )
        .await
        .unwrap();

    let status =
        bulk_delete_by_author(&app, &channel, &outsider.0, &outsider.1.0.to_string(), 15).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}
