// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A poll count republished after an account deletion takes its version under the
//! write lock, as a vote does, so a vote still in flight cannot lose to a stale frame.

use std::time::Duration;

use slimm_server::ids::MessageId;
use slimm_server::store::NewPoll;

use crate::support;

#[tokio::test]
async fn poll_outcome_waits_for_a_write_in_flight() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-poll-outcome-lock").await;
    let user = store.create_user("nia", "Nia").await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let message = MessageId::generate();
    let options = ["tabs".to_owned(), "spaces".to_owned()];
    store
        .send_poll_message(
            channel.id,
            user.id,
            message,
            "",
            NewPoll {
                question: "tabs or spaces?",
                options: &options,
                close_at: None,
                ranked: false,
            },
            None,
        )
        .await
        .unwrap();

    let writer = pool.begin_with("BEGIN IMMEDIATE").await.unwrap();
    let reader = store.clone();
    let outcome = tokio::spawn(async move { reader.poll_outcome(message).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !outcome.is_finished(),
        "the count was read while a write was in flight"
    );

    writer.commit().await.unwrap();
    let outcome = outcome.await.unwrap().unwrap().expect("the poll exists");
    assert_eq!(outcome.tally.len(), 2);
}
