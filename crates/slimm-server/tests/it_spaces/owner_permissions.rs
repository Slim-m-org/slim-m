// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space owner holds every permission whatever their roles, and no overwrite takes one away,
//! on every read path: per channel, batched, the rail, push fan-out and `/me`.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelCategoryId, ChannelId, RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{OverwriteBatchEntry, Store};

use crate::support;
use support::app::{Account, app, call_as, general_channel_id, register_account};

const VIEW: Permissions = Permissions::VIEW_CHANNEL;
const VIEW_SEND: Permissions = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);

/// alice owns the Space and has given up the `admin` role; bob is a member.
struct World {
    app: Router,
    store: Store,
    pool: sqlx::SqlitePool,
    alice: Account,
    bob: Account,
    admin: RoleId,
    everyone: RoleId,
    _guard: support::TestDbGuard,
}

fn id(value: &Value) -> uuid::Uuid {
    value["id"].as_str().unwrap().parse().unwrap()
}

async fn ok(app: &Router, token: &str, method: &str, uri: &str, body: Option<Value>) -> Value {
    let (status, body) = call_as(app, method, uri, token, body).await;
    assert!(status.is_success(), "{method} {uri}: {status} {body}");
    body
}

async fn world(prefix: &str) -> World {
    let (store, pool, guard) = support::new_store_with_pool(prefix).await;
    let app = app(store.clone());
    let alice = register_account(&store, "alice").await;
    let bob = register_account(&store, "bob").await;
    let roles = store.list_roles().await.unwrap();
    let admin = roles.iter().find(|r| r.name == "admin").unwrap().id;
    let everyone = roles.iter().find(|r| r.is_everyone).unwrap().id;
    let own = format!("/members/{}/roles/{admin}", alice.id);
    ok(&app, &alice.token, "DELETE", &own, None).await;
    World {
        app,
        store,
        pool,
        alice,
        bob,
        admin,
        everyone,
        _guard: guard,
    }
}

impl World {
    async fn base(&self, user: UserId) -> Permissions {
        self.store.base_permissions(user).await.unwrap()
    }

    async fn me(&self, token: &str) -> Value {
        ok(&self.app, token, "GET", "/me", None).await
    }

    async fn general(&self) -> ChannelId {
        ChannelId(general_channel_id(&self.store).await.parse().unwrap())
    }

    /// A channel in a category, both hidden from `@everyone`, the channel also denying alice.
    async fn hidden(&self) -> (ChannelCategoryId, ChannelId) {
        let body = json!({ "name": "staff" });
        let staff = ok(
            &self.app,
            &self.alice.token,
            "POST",
            "/categories",
            Some(body),
        )
        .await;
        let staff = ChannelCategoryId(id(&staff));
        let body = json!({ "name": "staff-chat", "category_id": staff.to_string() });
        let chat = ok(
            &self.app,
            &self.alice.token,
            "POST",
            "/channels",
            Some(body),
        )
        .await;
        let chat = ChannelId(id(&chat));
        let hide = OverwriteBatchEntry {
            target_type: "role",
            target_id: self.everyone.0,
            allow: Permissions::NONE,
            deny: VIEW,
        };
        self.store
            .set_category_overwrites(staff, &[hide])
            .await
            .unwrap();
        let deny = Permissions::NONE;
        self.store
            .set_role_overwrite(chat, self.everyone, deny, VIEW)
            .await
            .unwrap();
        self.store
            .set_member_overwrite(chat, self.alice.id, deny, VIEW_SEND)
            .await
            .unwrap();
        (staff, chat)
    }

    async fn point_owner_at(&self, user: UserId) {
        sqlx::query("UPDATE space_settings SET owner_id = ? WHERE id = 1")
            .bind(user)
            .execute(&self.pool)
            .await
            .unwrap();
    }
}

fn every_bit() -> impl Iterator<Item = Permissions> {
    (0..63)
        .map(|bit| Permissions::from_bits(1 << bit))
        .filter(|bit| Permissions::ALL.contains(*bit))
}

#[tokio::test]
async fn the_owner_with_no_roles_holds_and_uses_every_permission() {
    let w = world("slimm-owner-perms-all").await;
    let body = json!({ "permissions": 0 });
    let everyone = format!("/roles/{}", w.everyone);
    ok(&w.app, &w.alice.token, "PATCH", &everyone, Some(body)).await;
    let general = w.general().await;

    assert_eq!(w.base(w.alice.id).await, Permissions::ALL);
    let in_general = w.store.permissions_in_channel(w.alice.id, general).await;
    assert_eq!(in_general.unwrap(), Permissions::ALL);
    for bit in every_bit() {
        assert!(w.base(w.alice.id).await.contains(bit), "{bit:?}");
    }
    let me = w.me(&w.alice.token).await;
    assert_eq!(me["permissions"], Permissions::ALL.bits(), "{me}");
    assert_eq!(me["is_owner"], true, "{me}");
    let alerted = w.store.admin_alert_recipients().await.unwrap();
    assert_eq!(alerted, vec![w.alice.id]);

    let bob = w.bob.id;
    let message = json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "still here" });
    let role = json!({ "name": "wardens", "permissions": Permissions::ADMINISTRATOR.bits() });
    let timeout = json!({ "duration_seconds": 60 });
    let acts: [(&str, String, Option<Value>); 7] = [
        (
            "POST",
            format!("/channels/{general}/messages"),
            Some(message),
        ),
        ("POST", "/channels".into(), Some(json!({ "name": "new" }))),
        ("POST", "/roles".into(), Some(role)),
        ("POST", "/invites".into(), Some(json!({}))),
        ("GET", "/space/settings".into(), None),
        ("GET", "/reports/history".into(), None),
        ("PUT", format!("/members/{bob}/timeout"), Some(timeout)),
    ];
    for (method, uri, body) in acts {
        ok(&w.app, &w.alice.token, method, &uri, body).await;
    }
}

#[tokio::test]
async fn non_owners_keep_exactly_what_their_roles_grant() {
    let w = world("slimm-owner-perms-others").await;
    let carol = register_account(&w.store, "carol").await;
    let grant = format!("/members/{}/roles/{}", carol.id, w.admin);
    ok(&w.app, &w.alice.token, "PUT", &grant, None).await;

    let bob = w.base(w.bob.id).await;
    assert!(!bob.contains(Permissions::MANAGE_SERVER), "{bob:?}");
    assert_eq!(w.me(&w.bob.token).await["is_owner"], false);
    let (status, _) = call_as(&w.app, "GET", "/space/settings", &w.bob.token, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(w.base(carol.id).await, Permissions::ALL);
    assert_eq!(w.me(&carol.token).await["is_owner"], false);
}

#[tokio::test]
async fn an_overwrite_denying_the_owner_view_or_send_changes_nothing() {
    let w = world("slimm-owner-perms-overwrites").await;
    let (_, chat) = w.hidden().await;
    let muted = w.store.create_role("muted", Permissions::NONE, false).await;
    let muted = muted.unwrap();
    w.store
        .set_role_overwrite(chat, muted, Permissions::NONE, VIEW_SEND)
        .await
        .unwrap();
    w.store.assign_role(w.alice.id, muted).await.unwrap();

    let held = w.store.permissions_in_channel(w.alice.id, chat).await;
    assert_eq!(held.unwrap(), Permissions::ALL);
    let message = json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hello" });
    let uri = format!("/channels/{chat}/messages");
    ok(&w.app, &w.alice.token, "POST", &uri, Some(message)).await;
    ok(&w.app, &w.alice.token, "GET", &uri, None).await;

    let bobs = w.store.permissions_in_channel(w.bob.id, chat).await;
    assert!(!bobs.unwrap().contains(VIEW));
    let message = json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "let me in" });
    let (status, body) = call_as(&w.app, "POST", &uri, &w.bob.token, Some(message)).await;
    assert!(status.is_client_error(), "{status} {body}");
}

#[tokio::test]
async fn the_owner_sees_every_hidden_channel_and_category_on_every_read_path() {
    let w = world("slimm-owner-perms-hidden").await;
    let (staff, chat) = w.hidden().await;

    let channels = ok(&w.app, &w.alice.token, "GET", "/channels", None).await;
    let row = channels
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == chat.to_string())
        .unwrap_or_else(|| panic!("the owner lost a hidden channel: {channels}"));
    assert_eq!(row["permissions"], Permissions::ALL.bits(), "{row}");
    assert_eq!(row["restricted"], true, "{row}");
    let categories = ok(&w.app, &w.alice.token, "GET", "/categories", None).await;
    let has_staff = |list: &Value| {
        let staff = staff.to_string();
        list.as_array().unwrap().iter().any(|c| c["id"] == staff)
    };
    assert!(has_staff(&categories), "{categories}");

    let theirs = ok(&w.app, &w.bob.token, "GET", "/channels", None).await;
    let leaked = theirs.as_array().unwrap().iter();
    assert!(
        !leaked.clone().any(|c| c["id"] == chat.to_string()),
        "{theirs}"
    );
    let theirs = ok(&w.app, &w.bob.token, "GET", "/categories", None).await;
    assert!(!has_staff(&theirs), "{theirs}");

    let both = [w.alice.id, w.bob.id];
    let viewers = w.store.viewers_among(chat, &both).await.unwrap();
    assert_eq!(viewers, vec![w.alice.id]);
    let batch = w.store.permissions_in_channels(w.alice.id, &[chat]).await;
    assert_eq!(batch.unwrap()[&chat], Permissions::ALL);
    let visible = w.store.visible_channels(w.alice.id).await.unwrap();
    assert!(visible.iter().any(|c| c.id == chat));
}

/// Nothing in the API removes the owner, so the removal is written by hand.
#[tokio::test]
async fn ownership_handed_to_the_earliest_member_holds_every_permission() {
    let w = world("slimm-owner-perms-heir").await;
    let carol = register_account(&w.store, "carol").await;
    sqlx::query("UPDATE users SET created_at = created_at + 60000 WHERE id = ?")
        .bind(carol.id)
        .execute(&w.pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO space_removals (user_id, removed_by, removed_at) VALUES (?, ?, 0)")
        .bind(w.alice.id)
        .bind(w.alice.id)
        .execute(&w.pool)
        .await
        .unwrap();
    assert!(
        !w.base(w.alice.id)
            .await
            .contains(Permissions::ADMINISTRATOR)
    );

    let me = w.me(&w.bob.token).await;
    assert_eq!(me["is_owner"], true, "{me}");
    assert_eq!(me["permissions"], Permissions::ALL.bits(), "{me}");
    ok(&w.app, &w.bob.token, "GET", "/space/settings", None).await;
    let carols = w.base(carol.id).await;
    assert!(!carols.contains(Permissions::MANAGE_SERVER), "{carols:?}");
}

#[tokio::test]
async fn an_heir_by_account_deletion_keeps_everything_without_a_role() {
    let w = world("slimm-owner-perms-deleted").await;
    let regrant = format!("/members/{}/roles/{}", w.bob.id, w.admin);
    ok(&w.app, &w.alice.token, "PUT", &regrant, None).await;
    w.store.delete_account(w.alice.id).await.unwrap();
    assert_eq!(w.store.space_owner().await.unwrap(), Some(w.bob.id));

    let own = format!("/members/{}/roles/{}", w.bob.id, w.admin);
    ok(&w.app, &w.bob.token, "DELETE", &own, None).await;
    assert_eq!(w.base(w.bob.id).await, Permissions::ALL);
}

#[tokio::test]
async fn an_owner_id_on_a_bot_or_a_removed_account_grants_nothing() {
    let w = world("slimm-owner-perms-not-live").await;
    let (_, chat) = w.hidden().await;
    let send = Permissions::SEND_MESSAGES;
    let bot = w.store.create_bot("warden", "Warden", send, w.alice.id);
    let bot = bot.await.unwrap().bot.user_id;
    let removed = w.bob.id;
    w.store
        .remove_from_space(removed, w.alice.id, None)
        .await
        .unwrap();

    w.point_owner_at(bot).await;
    let bots = w.base(bot).await;
    assert!(!bots.contains(Permissions::ADMINISTRATOR), "{bots:?}");
    assert!(!bots.contains(Permissions::MANAGE_SERVER), "{bots:?}");
    let seen = w.store.viewers_among(chat, &[bot]).await.unwrap();
    assert!(seen.is_empty(), "a bot owner id saw a hidden channel");
    let recipients = w.store.admin_alert_recipients().await.unwrap();
    assert!(!recipients.contains(&bot), "{recipients:?}");

    w.point_owner_at(removed).await;
    let theirs = w.base(removed).await;
    assert!(!theirs.contains(Permissions::ADMINISTRATOR), "{theirs:?}");
    let held = w.store.permissions_in_channel(removed, chat).await.unwrap();
    assert!(!held.contains(VIEW), "{held:?}");
}
