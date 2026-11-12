// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /search/messages`: the cross-channel scope the command palette uses,
//! as opposed to the per-channel `basic`/`operators_*` siblings.
//!
//! [`search_never_returns_a_hit_from_a_channel_the_caller_cannot_view`] is
//! the acceptance criterion for this whole feature: a caller must never get
//! a message hit from a channel they cannot view, so it plants a real,
//! matching message straight through the store (bypassing HTTP permission
//! checks entirely) in a channel the searching caller is denied
//! `VIEW_CHANNEL` in, the same shape `operators_identity.rs`'s `in:` leak
//! test already uses for the per-channel route's own `in:` operator.

use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::NewMessage;
use tower::ServiceExt;

use crate::message_search::fixtures::*;

/// With no `in:`, the scope is every channel the caller can view: a matching
/// message in either of two ordinary channels is returned, not just the one
/// named by a path (there is no path here at all).
#[tokio::test]
async fn search_finds_messages_across_every_viewable_channel() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let alpha = store.create_channel("alpha", "text").await.unwrap();
    let bravo = store.create_channel("bravo", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    send(&app, &alpha.id.to_string(), &token, "narwhals in alpha").await;
    send(&app, &bravo.id.to_string(), &token, "narwhals in bravo").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                "/search/messages?q=narwhals",
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let mut contents: Vec<&str> = results
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["content"].as_str().unwrap())
        .collect();
    contents.sort_unstable();
    assert_eq!(contents, vec!["narwhals in alpha", "narwhals in bravo"]);
}

/// The acceptance criterion for this feature: a caller must never get a
/// message hit from a channel they cannot view. `vault` denies `@everyone`
/// `VIEW_CHANNEL`; its matching message is planted straight through the
/// store, bypassing HTTP permission checks entirely, so this test would
/// still pass with the permission check deleted only if `vault` had no
/// matching message at all - it does, so the only thing that can make this
/// pass is the scope really excluding it.
#[tokio::test]
async fn search_never_returns_a_hit_from_a_channel_the_caller_cannot_view() {
    let (store, _guard) = new_store().await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let lobby = store.create_channel("lobby", "text").await.unwrap();
    let vault = store.create_channel("vault", "text").await.unwrap();
    store
        .set_role_overwrite(
            vault.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    send(&app, &lobby.id.to_string(), &token, "checking the lobby").await;
    let planter = store
        .create_account("ghost", "ghost", "not-a-real-hash")
        .await
        .unwrap();
    store
        .send_message(NewMessage::plain(
            vault.id,
            planter.id,
            MessageId::generate(),
            "checking the vault too",
        ))
        .await
        .unwrap();

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                "/search/messages?q=checking",
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
        "only the viewable lobby hit should return"
    );
    assert_eq!(results[0]["content"], "checking the lobby");
    assert_eq!(results[0]["channel_id"], lobby.id.to_string());
}

/// A caller who can view nothing at all gets an empty array, not an error:
/// the same "no viewable scope answers empty" rule the `in:` oracle-safety
/// tests already pin, applied to the default (no `in:`) scope.
#[tokio::test]
async fn search_with_nothing_viewable_answers_empty() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    store.create_channel("private", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            "/search/messages?q=anything",
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    let results = json_body(response).await;
    assert_eq!(results.as_array().unwrap().len(), 0);
}

/// `in:` still narrows the cross-channel scope to one named channel, exactly
/// as it narrows the per-channel route away from its path channel.
#[tokio::test]
async fn in_narrows_the_cross_channel_scope_to_one_named_channel() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let alpha = store.create_channel("alpha", "text").await.unwrap();
    let bravo = store.create_channel("bravo", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    send(&app, &alpha.id.to_string(), &token, "narwhals in alpha").await;
    send(&app, &bravo.id.to_string(), &token, "narwhals in bravo").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                "/search/messages?q=narwhals&in=bravo",
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["content"], "narwhals in bravo");
}

/// The default (no `in:`) scope excludes DMs the caller is a party to, the
/// same way it excludes any channel `Store::visible_channels` never lists -
/// a DM's `VIEW_CHANNEL` comes from `dm_permissions`, not the ordinary
/// evaluator `visible_channels` runs, so it is out of scope by construction,
/// not by an extra check that could be forgotten.
#[tokio::test]
async fn search_excludes_the_callers_own_dms() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let lobby = store.create_channel("lobby", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let bob = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let alice_id = store
        .user_ids_for_usernames(&["alice".to_owned()])
        .await
        .unwrap()[0];
    let dm = store.open_dm(alice_id, bob.id).await.unwrap();

    send(&app, &lobby.id.to_string(), &token, "checking things").await;
    store
        .send_message(NewMessage::plain(
            dm.id,
            bob.id,
            MessageId::generate(),
            "checking things privately",
        ))
        .await
        .unwrap();

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                "/search/messages?q=checking",
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["channel_id"], lobby.id.to_string());
}

/// Cross-channel results are ordered newest-first by wall-clock time, not by
/// per-channel `seq`. `seq` is per-channel, so ordering a multi-channel result
/// by it would rank a chatty channel's older message above a quiet channel's
/// newer one. The chatty channel here holds `seq` 1 and 2; the quiet channel's
/// single message (`seq` 1) is sent last and must come back first.
#[tokio::test]
async fn cross_channel_results_are_ordered_by_time_not_per_channel_seq() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let chatty = store.create_channel("chatty", "text").await.unwrap();
    let quiet = store.create_channel("quiet", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    // Distinct milliseconds so created_at, not the seq tiebreak, decides order.
    send(&app, &chatty.id.to_string(), &token, "beluga one").await;
    tokio::time::sleep(std::time::Duration::from_millis(2)).await;
    send(&app, &chatty.id.to_string(), &token, "beluga two").await;
    tokio::time::sleep(std::time::Duration::from_millis(2)).await;
    send(&app, &quiet.id.to_string(), &token, "beluga three").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                "/search/messages?q=beluga",
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let contents: Vec<&str> = results
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["content"].as_str().unwrap())
        .collect();
    assert_eq!(
        contents,
        vec!["beluga three", "beluga two", "beluga one"],
        "newest by time first, not the chatty channel's higher seq"
    );
}
