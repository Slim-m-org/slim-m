// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A poll or app message is refused inside its own write transaction when the
//! author last sent inside the slow-mode window, so two launches that both
//! passed an early read cannot both land. A retry of a stored id is never
//! refused, and without a window nothing is.

use slimm_server::ids::MessageId;
use slimm_server::store::{
    AppLaunch, CreateAppSurfaceError, CreatePollError, NewPoll, Store, User,
};

use crate::support;
const WINDOW_MS: i64 = 60_000;

async fn world(
    prefix: &str,
) -> (
    Store,
    User,
    slimm_server::ids::ChannelId,
    support::TestDbGuard,
) {
    let (store, guard) = support::new_store(prefix).await;
    let user = store.create_user("nia", "Nia").await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    (store, user, channel.id, guard)
}

fn poll(options: &[String]) -> NewPoll<'_> {
    NewPoll {
        question: "tabs or spaces?",
        options,
        close_at: None,
        ranked: false,
    }
}

fn launch() -> AppLaunch<'static> {
    AppLaunch {
        module_id: "widget",
        command: "surf",
    }
}

#[tokio::test]
async fn a_second_app_message_inside_the_window_is_refused_under_the_write_lock() {
    let (store, user, channel, _guard) = world("slimm-store-slow-app").await;
    let first = store
        .send_app_message(
            channel,
            user.id,
            MessageId::generate(),
            "",
            launch(),
            Some(WINDOW_MS),
        )
        .await
        .unwrap();
    assert!(first.fresh);

    let second = store
        .send_app_message(
            channel,
            user.id,
            MessageId::generate(),
            "",
            launch(),
            Some(WINDOW_MS),
        )
        .await;

    assert!(
        matches!(
            second,
            Err(CreateAppSurfaceError::SlowMode {
                retry_after_seconds: 1..=60
            })
        ),
        "{second:?}"
    );
}

#[tokio::test]
async fn an_app_message_without_a_window_is_never_refused() {
    let (store, user, channel, _guard) = world("slimm-store-slow-app-off").await;
    for _ in 0..2 {
        let sent = store
            .send_app_message(channel, user.id, MessageId::generate(), "", launch(), None)
            .await
            .unwrap();
        assert!(sent.fresh);
    }
}

#[tokio::test]
async fn a_retried_app_message_is_returned_not_refused() {
    let (store, user, channel, _guard) = world("slimm-store-slow-app-retry").await;
    let id = MessageId::generate();
    store
        .send_app_message(channel, user.id, id, "", launch(), Some(WINDOW_MS))
        .await
        .unwrap();
    let retry = store
        .send_app_message(channel, user.id, id, "", launch(), Some(WINDOW_MS))
        .await
        .unwrap();
    assert!(!retry.fresh);
}

#[tokio::test]
async fn a_second_poll_inside_the_window_is_refused_under_the_write_lock() {
    let (store, user, channel, _guard) = world("slimm-store-slow-poll").await;
    let options = ["tabs".to_owned(), "spaces".to_owned()];
    let first = store
        .send_poll_message(
            channel,
            user.id,
            MessageId::generate(),
            "",
            poll(&options),
            Some(WINDOW_MS),
        )
        .await
        .unwrap();
    assert!(first.fresh);

    let second = store
        .send_poll_message(
            channel,
            user.id,
            MessageId::generate(),
            "",
            poll(&options),
            Some(WINDOW_MS),
        )
        .await;

    assert!(
        matches!(
            second,
            Err(CreatePollError::SlowMode {
                retry_after_seconds: 1..=60
            })
        ),
        "{second:?}"
    );
}
