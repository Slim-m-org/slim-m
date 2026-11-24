// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Decision 0136: a member on Do not disturb is woken by no message, mention or `@everyone`.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{DeviceId, UserId};
use slimm_server::presence::Visibility;
use slimm_server::store::{PushRegistration, Store};

use crate::support;
use support::wake_recipients;

const KEY: [u8; 32] = [7u8; 32];

async fn account(store: &Store, username: &str) -> UserId {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "phone").await.unwrap();
    register(store, account.id, session.device_id).await;
    account.id
}

async fn register(store: &Store, user: UserId, device: DeviceId) {
    store
        .register_push(
            user,
            device,
            PushRegistration {
                platform: "ios",
                push_token: &format!("token-{user}"),
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn do_not_disturb_drops_plain_messages_mentions_and_everyone() {
    let (path, _guard) = support::TestDbGuard::new("slimm-dnd-chat");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let alice = account(&store, "alice").await;
    let bob = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    for text in ["just chatting", "hi @bob", "@everyone look"] {
        let before = wake_recipients(&store, channel, alice, text).await.unwrap();
        assert!(
            before.contains(&bob),
            "bob is reachable for {text:?}: {before:?}"
        );
    }

    store
        .set_presence_visibility(bob, Visibility::Dnd)
        .await
        .unwrap();
    for text in ["just chatting", "hi @bob", "@everyone look"] {
        let during = wake_recipients(&store, channel, alice, text).await.unwrap();
        assert!(!during.contains(&bob), "dnd silences {text:?}: {during:?}");
    }

    store
        .set_presence_visibility(bob, Visibility::Online)
        .await
        .unwrap();
    let after = wake_recipients(&store, channel, alice, "hi @bob")
        .await
        .unwrap();
    assert!(
        after.contains(&bob),
        "leaving dnd restores pushes: {after:?}"
    );
}
