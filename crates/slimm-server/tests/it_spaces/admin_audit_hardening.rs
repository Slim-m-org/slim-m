// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin audit log keeps a row for every change: a long detail is clipped, a replay writes
//! once, a body without a length is still read, and a reader never sees a channel it cannot view.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{ModerationHistoryItem, NewMessage, Store};
use tower::ServiceExt;

use crate::support;
use support::app::{app, json_body};

struct Deployment {
    store: Store,
    admin: UserId,
    admin_token: String,
    general: ChannelId,
    _guard: support::TestDbGuard,
}

async fn deployment(prefix: &str) -> Deployment {
    let (store, guard) = support::new_store(prefix).await;
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    store
        .create_role("everyone", view_send, true)
        .await
        .unwrap();
    let admin_role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = store.create_user("root", "Root").await.unwrap();
    store.assign_role(admin.id, admin_role).await.unwrap();
    let admin_token = token(&store, admin.id).await;
    let general = store.create_channel("general", "text").await.unwrap().id;
    Deployment {
        store,
        admin: admin.id,
        admin_token,
        general,
        _guard: guard,
    }
}

async fn token(store: &Store, user: UserId) -> String {
    store
        .open_session(user, "laptop")
        .await
        .unwrap()
        .access_token
}

async fn member_with(store: &Store, name: &str, permissions: Permissions) -> (UserId, String) {
    let role = store.create_role(name, permissions, false).await.unwrap();
    let user = store.create_user(name, name).await.unwrap();
    store.assign_role(user.id, role).await.unwrap();
    (user.id, token(store, user.id).await)
}

fn json_request(method: &str, uri: &str, token: &str, body: &Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn bare(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn log(router: &Router, token: &str) -> Vec<Value> {
    let response = router
        .clone()
        .oneshot(bare("GET", "/space/audit-log", token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await.as_array().unwrap().clone()
}

async fn new_role(router: &Router, token: &str) -> String {
    let created = router
        .clone()
        .oneshot(json_request(
            "POST",
            "/roles",
            token,
            &json!({ "name": "mods", "permissions": 0 }),
        ))
        .await
        .unwrap();
    json_body(created).await["id"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn a_change_with_a_very_long_detail_still_writes_a_clipped_row() {
    let d = deployment("slimm-audit-long-detail").await;
    let router = app(d.store.clone());

    let mut body = json!({ "channel_ids": [d.general.to_string()] });
    body["k".repeat(5000)] = json!(1);
    let changed = router
        .clone()
        .oneshot(json_request(
            "PUT",
            "/channels/order",
            &d.admin_token,
            &body,
        ))
        .await
        .unwrap();
    assert!(changed.status().is_success(), "{}", changed.status());

    let entries = log(&router, &d.admin_token).await;
    let row = entries.iter().find(|e| e["action"] == "channel.reorder");
    let row = row.unwrap_or_else(|| panic!("no channel.reorder row in {entries:?}"));
    assert_eq!(row["actor_id"], d.admin.to_string());
    assert!(row["detail"].to_string().len() < 4096);
}

#[tokio::test]
async fn a_replayed_delete_writes_one_row_and_two_deletes_write_two() {
    let d = deployment("slimm-audit-replay").await;
    let first = d.store.create_channel("first", "text").await.unwrap().id;
    let second = d.store.create_channel("second", "text").await.unwrap().id;
    let router = app(d.store.clone());

    for channel in [first, first, second] {
        let deleted = router
            .clone()
            .oneshot(bare(
                "DELETE",
                &format!("/channels/{channel}"),
                &d.admin_token,
            ))
            .await
            .unwrap();
        assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    }

    let entries = log(&router, &d.admin_token).await;
    let deletes: Vec<&Value> = entries
        .iter()
        .filter(|e| e["action"] == "channel.delete")
        .collect();
    assert_eq!(deletes.len(), 2, "{entries:?}");
}

#[tokio::test]
async fn a_body_without_a_length_still_records_its_fields() {
    let d = deployment("slimm-audit-chunked").await;
    let router = app(d.store.clone());
    let role_id = new_role(&router, &d.admin_token).await;

    let chunked = Request::builder()
        .method("PATCH")
        .uri(format!("/roles/{role_id}"))
        .header("authorization", format!("Bearer {}", d.admin_token))
        .header("content-type", "application/json")
        .body(Body::from_stream(futures_util::stream::iter([
            Ok::<_, std::io::Error>(axum::body::Bytes::from_static(b"{\"name\":\"chun")),
            Ok(axum::body::Bytes::from_static(b"ked\"}")),
        ])))
        .unwrap();
    let renamed = router.clone().oneshot(chunked).await.unwrap();
    assert!(renamed.status().is_success(), "{}", renamed.status());

    let entries = log(&router, &d.admin_token).await;
    assert_eq!(entries[0]["action"], "role.update");
    assert_eq!(entries[0]["detail"]["name"], "chunked", "{entries:?}");
}

#[tokio::test]
async fn a_manager_who_cannot_view_a_private_channel_reads_its_rows_redacted() {
    let d = deployment("slimm-audit-redaction").await;
    let (manager, manager_token) =
        member_with(&d.store, "manager", Permissions::MANAGE_SERVER).await;
    let secret = d
        .store
        .create_channel("secret-plans", "text")
        .await
        .unwrap()
        .id;
    let open = d
        .store
        .create_channel("town-square", "text")
        .await
        .unwrap()
        .id;
    d.store
        .set_member_overwrite(
            secret,
            manager,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    for (channel, name) in [(secret, "secret-plans"), (open, "town-square")] {
        d.store
            .record_admin_change(
                d.admin,
                "channel.update",
                Some(&channel.to_string()),
                &json!({ "name": name, "fields": ["name"] }).to_string(),
            )
            .await
            .unwrap();
    }
    let router = app(d.store.clone());

    let seen = log(&router, &manager_token).await;
    let by_target = |id: ChannelId| {
        seen.iter()
            .find(|e| e["target_id"] == id.to_string())
            .unwrap()
    };
    assert!(
        by_target(secret)["detail"].get("name").is_none(),
        "{seen:?}"
    );
    assert_eq!(by_target(open)["detail"]["name"], "town-square");
    let as_admin = log(&router, &d.admin_token).await;
    assert!(
        as_admin
            .iter()
            .any(|e| e["detail"]["name"] == "secret-plans")
    );
}

async fn author_and_message(d: &Deployment) -> (UserId, ChannelId, MessageId) {
    let author = d.store.create_user("author", "Author").await.unwrap().id;
    let channel = d.general;
    let sent = d
        .store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap();
    (author, channel, sent.message.id)
}

async fn audit_rows(store: &Store) -> Vec<(String, Option<String>, UserId)> {
    let items = store.moderation_history(None, &[], 50).await.unwrap();
    items
        .into_iter()
        .filter_map(|item| match item {
            ModerationHistoryItem::Audit(entry) => {
                Some((entry.action, entry.reason, entry.subject_id))
            }
            ModerationHistoryItem::ResolvedReport(_) => None,
        })
        .collect()
}

#[tokio::test]
async fn a_moderator_pin_and_unpin_of_someone_elses_message_are_recorded_and_ones_own_are_not() {
    let d = deployment("slimm-audit-pins").await;
    let (author, channel, message) = author_and_message(&d).await;
    let own = d
        .store
        .send_message(NewMessage::plain(
            channel,
            d.admin,
            MessageId::generate(),
            "mine",
        ))
        .await
        .unwrap()
        .message
        .id;

    d.store.pin_message(channel, own, d.admin).await.unwrap();
    d.store.unpin_message(channel, own, d.admin).await.unwrap();
    assert!(audit_rows(&d.store).await.is_empty());

    d.store
        .pin_message(channel, message, d.admin)
        .await
        .unwrap();
    d.store
        .pin_message(channel, message, d.admin)
        .await
        .unwrap();
    d.store
        .unpin_message(channel, message, d.admin)
        .await
        .unwrap();
    d.store
        .unpin_message(channel, message, d.admin)
        .await
        .unwrap();
    let rows = audit_rows(&d.store).await;
    let pins: Vec<_> = rows
        .iter()
        .filter(|(action, ..)| action == "message_pin_changed")
        .map(|(_, reason, subject)| (reason.as_deref(), *subject))
        .collect();
    assert_eq!(
        pins,
        vec![(Some("unpinned"), author), (Some("pinned"), author)]
    );
}

#[tokio::test]
async fn removing_someone_elses_link_previews_is_recorded_once() {
    let d = deployment("slimm-audit-previews").await;
    let (author, channel, message) = author_and_message(&d).await;

    d.store
        .suppress_link_previews(channel, message, author)
        .await
        .unwrap();
    assert!(
        audit_rows(&d.store).await.is_empty(),
        "the author's own removal"
    );
    let other = author_and_message_two(&d).await;
    d.store
        .suppress_link_previews(channel, other, d.admin)
        .await
        .unwrap();
    d.store
        .suppress_link_previews(channel, other, d.admin)
        .await
        .unwrap();
    let rows = audit_rows(&d.store).await;
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(rows[0].0, "message_preview_removed");
}

async fn author_and_message_two(d: &Deployment) -> MessageId {
    let author = d
        .store
        .create_user("author2", "Author Two")
        .await
        .unwrap()
        .id;
    let channel = d.general;
    d.store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            "again",
        ))
        .await
        .unwrap()
        .message
        .id
}

#[tokio::test]
async fn renaming_a_webhook_is_recorded_with_the_new_label() {
    let d = deployment("slimm-audit-webhook-rename").await;
    let channel = d.general;
    let minted = d
        .store
        .create_webhook(channel, "ci", d.admin)
        .await
        .unwrap();
    let router = app(d.store.clone());

    let renamed = router
        .oneshot(json_request(
            "PATCH",
            &format!("/webhooks/{}", minted.webhook.id),
            &d.admin_token,
            &json!({ "label": "Staff Alice" }),
        ))
        .await
        .unwrap();
    assert_eq!(renamed.status(), StatusCode::OK);

    let rows = audit_rows(&d.store).await;
    assert!(
        rows.contains(&(
            "webhook_rename".to_owned(),
            Some("Staff Alice".to_owned()),
            minted.webhook.principal_id
        )),
        "{rows:?}"
    );
}

#[tokio::test]
async fn pruning_drops_rows_older_than_the_cutoff_from_both_logs() {
    let d = deployment("slimm-audit-prune").await;
    let (author, channel, message) = author_and_message(&d).await;
    d.store
        .record_admin_change(d.admin, "space.update", None, "{}")
        .await
        .unwrap();
    d.store
        .pin_message(channel, message, d.admin)
        .await
        .unwrap();

    assert_eq!(d.store.prune_audit_logs(0).await.unwrap(), 0);
    assert_eq!(
        slimm_server::run_audit_log_sweep_pass(&d.store)
            .await
            .unwrap(),
        0
    );
    assert_eq!(d.store.prune_audit_logs(i64::MAX).await.unwrap(), 2);
    assert!(audit_rows(&d.store).await.is_empty());
    let _ = author;
}
