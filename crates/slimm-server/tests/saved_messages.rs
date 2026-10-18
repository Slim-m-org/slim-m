// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Saved messages: private to one account, and re-checked against what that
//! account can see now rather than what it could see when it saved.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token as register, request_authed as request};

async fn send(app: &Router, channel: &str, token: &str, content: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel}/messages"),
                token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await
}

async fn saved_list(app: &Router, token: &str) -> Vec<Value> {
    json_body(
        app.clone()
            .oneshot(request("GET", "/saved", token, None))
            .await
            .unwrap(),
    )
    .await
    .as_array()
    .unwrap()
    .clone()
}

async fn save(app: &Router, token: &str, message_id: &str) -> StatusCode {
    save_response(app, token, message_id).await.status()
}

/// The whole response, for a test that has to compare bodies rather than just
/// status codes - a refusal that leaks its reason in the body is invisible to
/// a status-only assertion.
async fn save_response(app: &Router, token: &str, message_id: &str) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/messages/{message_id}/save"),
            token,
            None,
        ))
        .await
        .unwrap()
}

/// The ordinary path, and the ordering rule: keeping an old message puts it
/// at the top, because the list is by when it was saved.
#[tokio::test]
async fn saving_keeps_a_message_and_orders_by_when_it_was_kept() {
    let (store, _guard) = support::new_store("slimm-saved-messages").await;
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
    let channel = channel.id.to_string();

    let older = send(&app, &channel, &token, "the older message").await;
    let newer = send(&app, &channel, &token, "the newer message").await;

    // Saved in the opposite order to how they were sent.
    assert_eq!(
        save(&app, &token, newer["id"].as_str().unwrap()).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        save(&app, &token, older["id"].as_str().unwrap()).await,
        StatusCode::NO_CONTENT
    );

    let list = saved_list(&app, &token).await;
    assert_eq!(list.len(), 2);
    assert_eq!(
        list[0]["content"], "the older message",
        "newest save first, not newest message first"
    );
    assert_eq!(list[1]["content"], "the newer message");
    assert!(list[0]["saved_at"].is_i64());
}

/// A saved list is one account's own. Nobody else's save shows up in it, and
/// there is no route that takes a user id to get it wrong with.
#[tokio::test]
async fn one_persons_saves_are_invisible_to_another() {
    let (store, _guard) = support::new_store("slimm-saved-messages").await;
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
    let channel = channel.id.to_string();

    let message = send(&app, &channel, &alice, "worth keeping").await;
    save(&app, &alice, message["id"].as_str().unwrap()).await;

    assert_eq!(saved_list(&app, &alice).await.len(), 1);
    assert!(
        saved_list(&app, &bob).await.is_empty(),
        "bob saved nothing, and alice's list is not his to read"
    );
}

/// The property this feature turns on. Access is revocable, and a saved list
/// is not a licence to keep reading a channel somebody was removed from.
#[tokio::test]
async fn losing_sight_of_a_channel_drops_its_saves_from_the_list() {
    let (store, _guard) = support::new_store("slimm-saved-messages").await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let open = store.create_channel("general", "text").await.unwrap();
    let secret = store.create_channel("private", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let kept = send(&app, &open.id.to_string(), &token, "still visible").await;
    let doomed = send(&app, &secret.id.to_string(), &token, "about to go dark").await;
    save(&app, &token, kept["id"].as_str().unwrap()).await;
    save(&app, &token, doomed["id"].as_str().unwrap()).await;
    assert_eq!(saved_list(&app, &token).await.len(), 2);

    store
        .set_role_overwrite(
            secret.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let list = saved_list(&app, &token).await;
    assert_eq!(list.len(), 1, "the unreadable one is gone from the answer");
    assert_eq!(list[0]["content"], "still visible");

    // The row survives, because a permission change must not destroy data.
    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", &token, None))
            .await
            .unwrap(),
    )
    .await;
    let user_id = slimm_server::ids::UserId(Uuid::parse_str(me["id"].as_str().unwrap()).unwrap());
    assert_eq!(
        store.list_saved_messages(user_id).await.unwrap().len(),
        2,
        "kept in storage; only the answer is filtered"
    );
}

/// Saving is idempotent, and must not quietly reorder a list on a double tap.
#[tokio::test]
async fn saving_twice_does_not_move_it_to_the_top() {
    let (store, _guard) = support::new_store("slimm-saved-messages").await;
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
    let channel = channel.id.to_string();

    let first = send(&app, &channel, &token, "first").await;
    let second = send(&app, &channel, &token, "second").await;
    save(&app, &token, first["id"].as_str().unwrap()).await;
    save(&app, &token, second["id"].as_str().unwrap()).await;
    let before = saved_list(&app, &token).await;

    assert_eq!(
        save(&app, &token, first["id"].as_str().unwrap()).await,
        StatusCode::NO_CONTENT
    );

    let after = saved_list(&app, &token).await;
    assert_eq!(after.len(), 2, "no duplicate row");
    assert_eq!(
        after[0]["id"], before[0]["id"],
        "re-saving leaves the original saved_at alone"
    );
}

/// A message in a channel the caller cannot see is refused as missing, never
/// as forbidden, so this cannot be used to probe for one.
#[tokio::test]
async fn saving_something_you_cannot_see_is_indistinguishable_from_missing() {
    let (store, _guard) = support::new_store("slimm-saved-messages").await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let hidden = store.create_channel("private", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let author = store.create_user("author", "Author").await.unwrap();
    let secret = slimm_server::ids::MessageId::generate();
    store
        .send_message(slimm_server::store::NewMessage::plain(
            hidden.id,
            author.id,
            secret,
            "the secret",
        ))
        .await
        .unwrap();

    let refused = save_response(&app, &token, &secret.to_string()).await;
    let unknown = save_response(&app, &token, &Uuid::now_v7().to_string()).await;

    assert_eq!(refused.status(), StatusCode::NOT_FOUND);
    assert_eq!(unknown.status(), StatusCode::NOT_FOUND);
    // Bodies too: a refusal naming its reason would leak the distinction, and a status-only assertion cannot see that.
    assert_eq!(
        json_body(refused).await,
        json_body(unknown).await,
        "a hidden message and a nonexistent one must be indistinguishable"
    );
    assert!(saved_list(&app, &token).await.is_empty());
}

/// Letting go is never refused: not by a lost permission, and not by the
/// message having since been deleted - which is exactly the entry somebody
/// most wants gone.
#[tokio::test]
async fn unsaving_works_even_once_the_message_is_gone() {
    let (store, _guard) = support::new_store("slimm-saved-messages").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let channel = channel.id.to_string();

    let message = send(&app, &channel, &token, "regrettable").await;
    let id = message["id"].as_str().unwrap().to_owned();
    save(&app, &token, &id).await;

    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel}/messages/{id}"),
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    assert!(
        saved_list(&app, &token).await.is_empty(),
        "a deleted message leaves the list on its own"
    );

    let unsaved = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/messages/{id}/save"),
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(unsaved.status(), StatusCode::NO_CONTENT);
}

/// Deleting an account takes its saved list with it. The table's own
/// `ON DELETE CASCADE` does not do this: account deletion is a tombstone
/// `UPDATE`, never a row removal, so the cascade never fires and the purge
/// has to name this table like every other per-user one.
#[tokio::test]
async fn deleting_an_account_purges_its_saved_list() {
    let (store, _guard) = support::new_store("slimm-saved-messages").await;
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

    let message = send(&app, &channel_id, &token, "worth keeping").await;
    save(&app, &token, message["id"].as_str().unwrap()).await;

    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", &token, None))
            .await
            .unwrap(),
    )
    .await;
    let user_id = slimm_server::ids::UserId(Uuid::parse_str(me["id"].as_str().unwrap()).unwrap());
    assert_eq!(store.list_saved_messages(user_id).await.unwrap().len(), 1);

    store.delete_account(user_id).await.unwrap();

    assert!(
        store.list_saved_messages(user_id).await.unwrap().is_empty(),
        "a private list must not outlive the account that made it"
    );
}

/// A ceiling at the write, the call `MAX_PINS_PER_CHANNEL` already made: the
/// list is served whole, so it has to stay small enough to serve whole.
/// Without this `GET /saved` had no bound at all.
#[tokio::test]
async fn saving_stops_at_the_ceiling_but_re_saving_never_does() {
    let (store, _guard) = support::new_store("slimm-saved-messages").await;
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

    // Straight to the store; sending MAX_SAVED_MESSAGES+1 through the route would be a slow way to the same state.
    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", &token, None))
            .await
            .unwrap(),
    )
    .await;
    let user_id = slimm_server::ids::UserId(Uuid::parse_str(me["id"].as_str().unwrap()).unwrap());

    let mut first = None;
    for i in 0..slimm_server::store::MAX_SAVED_MESSAGES {
        let id = slimm_server::ids::MessageId::generate();
        store
            .send_message(slimm_server::store::NewMessage::plain(
                channel.id,
                user_id,
                id,
                &format!("message {i}"),
            ))
            .await
            .unwrap();
        store.save_message(user_id, id).await.unwrap();
        if first.is_none() {
            first = Some(id);
        }
    }

    let one_more = send(&app, &channel.id.to_string(), &token, "one too many").await;
    assert_eq!(
        save(&app, &token, one_more["id"].as_str().unwrap()).await,
        StatusCode::BAD_REQUEST,
        "the ceiling holds"
    );

    // Re-saving something already held adds no row, so it must not be refused for a ceiling it does not push against.
    assert_eq!(
        save(&app, &token, &first.unwrap().to_string()).await,
        StatusCode::NO_CONTENT,
        "an idempotent re-save is not a new save"
    );
}
