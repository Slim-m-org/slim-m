// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A device whose last WebSocket closes stops counting as foreground, so a
//! killed app is pushed to straight away instead of after the 60 s freshness.

use slimm_server::store::{PushRegistration, SessionContext, Store};

use crate::support;
use support::wait::wait_until_async;
use support::ws::{connect, serve};

const KEY: [u8; 32] = [7u8; 32];

struct Phone {
    ctx: SessionContext,
    store: Store,
}

async fn registered_foreground_phone(store: &Store) -> Phone {
    let user = store.create_user("alice", "Alice").await.unwrap();
    let tokens = store.open_session(user.id, "phone").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    store
        .register_push(
            user.id,
            ctx.device_id,
            PushRegistration {
                platform: "android",
                push_token: "token",
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();
    store
        .report_lifecycle(user.id, ctx.device_id, "foreground")
        .await
        .unwrap();
    Phone {
        ctx,
        store: store.clone(),
    }
}

impl Phone {
    async fn ticket(&self) -> String {
        self.store.mint_ws_ticket(&self.ctx).await.unwrap().0
    }

    async fn lifecycle(&self) -> Option<String> {
        let targets = self.store.push_targets(&[self.ctx.user_id]).await.unwrap();
        targets.into_iter().next().and_then(|t| t.lifecycle_state)
    }
}

#[tokio::test]
async fn closing_the_last_socket_backgrounds_the_device() {
    let (store, _guard) = support::new_store("slimm-push-socket-close").await;
    let phone = registered_foreground_phone(&store).await;
    let addr = serve(support::app::state(store.clone())).await;

    let ws = connect(addr, &phone.ticket().await).await;
    assert_eq!(phone.lifecycle().await.as_deref(), Some("foreground"));
    drop(ws);

    wait_until_async("the device to read as backgrounded", || async {
        phone.lifecycle().await.as_deref() == Some("background")
    })
    .await;
}

#[tokio::test]
async fn a_report_made_after_the_close_is_not_overwritten() {
    let (store, _guard) = support::new_store("slimm-push-socket-close-newer").await;
    let phone = registered_foreground_phone(&store).await;
    let targets = store.push_targets(&[phone.ctx.user_id]).await.unwrap();
    let reported_at = targets[0].lifecycle_reported_at.unwrap();

    store
        .report_socket_closed(phone.ctx.user_id, phone.ctx.device_id, reported_at - 1)
        .await
        .unwrap();

    assert_eq!(phone.lifecycle().await.as_deref(), Some("foreground"));
}

#[tokio::test]
async fn a_second_open_socket_keeps_the_device_foreground() {
    let (store, _guard) = support::new_store("slimm-push-socket-close-two").await;
    let phone = registered_foreground_phone(&store).await;
    let addr = serve(support::app::state(store.clone())).await;

    let first = connect(addr, &phone.ticket().await).await;
    let second = connect(addr, &phone.ticket().await).await;
    drop(first);
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert_eq!(phone.lifecycle().await.as_deref(), Some("foreground"));

    drop(second);
    wait_until_async("the device to read as backgrounded", || async {
        phone.lifecycle().await.as_deref() == Some("background")
    })
    .await;
}
