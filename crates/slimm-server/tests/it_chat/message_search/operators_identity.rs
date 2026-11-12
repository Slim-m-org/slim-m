// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `from:` and `in:`, the two operators that resolve a caller-supplied name
//! (a username, a channel name) against the deployment - so both carry the
//! same oracle-safety obligation: a name that resolves to nothing must
//! answer exactly like one that resolves to something the caller cannot
//! see. Plus `q` being optional now that operators can carry a whole search
//! on their own.

use axum::http::StatusCode;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::NewMessage;
use tower::ServiceExt;

use crate::message_search::fixtures::*;

/// `q` is optional now: an advanced search made entirely of operators still
/// runs, with no free text at all.
#[tokio::test]
async fn q_is_optional_when_at_least_one_filter_is_given() {
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

    send(&app, &channel_id, &token, "hello there").await;
    send(&app, &channel_id, &token, "general kenobi").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/messages/search?from=alice"),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(results.as_array().unwrap().len(), 2);
}

/// Neither `q` nor a single operator is a 400, not a whole-channel dump.
#[tokio::test]
async fn no_query_and_no_filter_is_a_bad_request() {
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
            &format!("/channels/{}/messages/search", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// `from:username` narrows to one author's own messages.
#[tokio::test]
async fn from_filters_to_one_authors_messages() {
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
    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let channel_id = channel.id.to_string();

    send(&app, &channel_id, &alice, "watching the sunrise").await;
    send(&app, &channel_id, &bob, "watching the sunrise too").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/messages/search?q=watching&from=bob"),
                Some(&alice),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["content"], "watching the sunrise too");
}

/// Usernames are unique ignoring case, so `from:` finds the author however it is typed.
#[tokio::test]
async fn from_matches_the_username_whatever_its_case() {
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
    let alice = register(&store, "Alice").await;
    let bob = register(&store, "bob").await;
    let channel_id = channel.id.to_string();

    send(&app, &channel_id, &alice, "watching the sunrise").await;
    send(&app, &channel_id, &bob, "watching the sunrise too").await;

    for typed in ["alice", "Alice", "ALICE"] {
        let results = json_body(
            app.clone()
                .oneshot(request(
                    "GET",
                    &format!("/channels/{channel_id}/messages/search?q=watching&from={typed}"),
                    Some(&bob),
                    None,
                ))
                .await
                .unwrap(),
        )
        .await;
        let results = results.as_array().unwrap();
        assert_eq!(results.len(), 1, "from={typed}");
        assert_eq!(
            results[0]["content"], "watching the sunrise",
            "from={typed}"
        );
    }
}

/// A `from:` naming nobody answers empty, the same as any other search that
/// happens to match nothing - not an error, and not a way to probe whether a
/// username is taken.
#[tokio::test]
async fn from_naming_no_such_account_answers_empty_not_an_error() {
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

    send(&app, &channel_id, &token, "watching the sunrise").await;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages/search?q=watching&from=nobody-here"),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let results = json_body(response).await;
    assert_eq!(results.as_array().unwrap().len(), 0);
}

/// `in:channel-name` searches a different channel than the one in the path,
/// as long as the caller may view it.
#[tokio::test]
async fn in_searches_a_named_channel_instead_of_the_path_channel() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel_a = store.create_channel("alpha", "text").await.unwrap();
    let channel_b = store.create_channel("bravo", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    send(&app, &channel_a.id.to_string(), &token, "narwhals in alpha").await;
    send(&app, &channel_b.id.to_string(), &token, "narwhals in bravo").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!(
                    "/channels/{}/messages/search?q=narwhals&in=bravo",
                    channel_a.id
                ),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 1, "only bravo's own message should match");
    assert_eq!(results[0]["content"], "narwhals in bravo");
}

/// `in:` naming a channel the caller cannot view, and `in:` naming a channel
/// that does not exist at all, both answer with an empty array - byte for
/// byte the same response - so neither can be used to learn a hidden channel
/// exists. Same shape as `mask_unless_viewable` in `permissions.rs`. The
/// hidden channel carries a real, matching message planted straight through
/// the store (bypassing HTTP permission checks entirely), or this test would
/// pass even with the permission check deleted, since an empty channel
/// answers empty regardless of whether it was ever checked.
#[tokio::test]
async fn in_naming_an_unviewable_or_nonexistent_channel_answers_empty_either_way() {
    let (store, _guard) = new_store().await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let visible = store.create_channel("lobby", "text").await.unwrap();
    let hidden = store.create_channel("vault", "text").await.unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    send(&app, &visible.id.to_string(), &token, "just checking in").await;
    let planter = store
        .create_account("ghost", "ghost", "not-a-real-hash")
        .await
        .unwrap();
    store
        .send_message(NewMessage::plain(
            hidden.id,
            planter.id,
            MessageId::generate(),
            "checking the vault too",
        ))
        .await
        .unwrap();

    let hidden_response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!(
                "/channels/{}/messages/search?q=checking&in=vault",
                visible.id
            ),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(hidden_response.status(), StatusCode::OK);
    let hidden_body = json_body(hidden_response).await;

    let missing_response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!(
                "/channels/{}/messages/search?q=checking&in=no-such-channel",
                visible.id
            ),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(missing_response.status(), StatusCode::OK);
    let missing_body = json_body(missing_response).await;

    assert_eq!(hidden_body.as_array().unwrap().len(), 0);
    assert_eq!(
        hidden_body, missing_body,
        "a real but unviewable channel and one that never existed must \
         answer identically"
    );
}

/// Channel names are not unique (`Store::search_channel_ids_by_name`'s own
/// doc), so `in:` can resolve to several candidates at once; each is checked
/// for `VIEW_CHANNEL` on its own, and only the viewable ones are searched.
/// This is the batched permission check's own test: a per-candidate loop and
/// a batched `permissions_in_channels` call must agree on exactly which
/// candidates survive, or this mixes in a channel the caller cannot see.
#[tokio::test]
async fn in_naming_two_same_named_channels_searches_only_the_viewable_one() {
    let (store, _guard) = new_store().await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let viewable = store.create_channel("standup", "text").await.unwrap();
    let hidden = store.create_channel("standup", "text").await.unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    send(&app, &viewable.id.to_string(), &token, "narwhals visible").await;
    let planter = store
        .create_account("ghost", "ghost", "not-a-real-hash")
        .await
        .unwrap();
    store
        .send_message(NewMessage::plain(
            hidden.id,
            planter.id,
            MessageId::generate(),
            "narwhals hidden",
        ))
        .await
        .unwrap();

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!(
                    "/channels/{}/messages/search?q=narwhals&in=standup",
                    viewable.id
                ),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(
        results.len(),
        1,
        "only the same-named channel the caller may view should match"
    );
    assert_eq!(results[0]["content"], "narwhals visible");
}
