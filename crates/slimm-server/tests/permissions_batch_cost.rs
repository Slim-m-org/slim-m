// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What `permissions_in_channels` costs, asserted rather than described.
//!
//! `store/permissions_batch.rs` carried its query cost in a doc comment
//! because this suite had no way to count statements. That comment was wrong
//! once already (see `viewers_among`'s own note on 2026-07-30) and out of date
//! a second time: the function looped a channel fetch per requested id while
//! `may_link` fed it every channel that has ever attached one sha256, on the
//! message-send path.
//!
//! sqlx emits one `sqlx::query` tracing event per statement it runs, so a
//! subscriber counting those events is a statement counter. It has to be the
//! global subscriber, not a thread-local `set_default` one: sqlite is
//! synchronous, so sqlx runs each connection on a worker thread of its own and
//! the event is emitted there. A thread-local counter reads zero and every
//! assertion below then passes vacuously, which is what the first check here
//! guards against.
//!
//! One global counter means one test: this file is deliberately a single
//! sequence rather than three tests that would interleave each other's counts.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tracing::Subscriber;
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;

async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-perm-cost-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

struct CountQueries(Arc<AtomicUsize>);

impl<S: Subscriber> Layer<S> for CountQueries {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() == "sqlx::query" {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// Runs `work` and answers how many statements it took, against the counter
/// installed for the whole binary.
async fn queries_for<T>(
    count: &AtomicUsize,
    work: impl std::future::Future<Output = T>,
) -> (usize, T) {
    let before = count.load(Ordering::Relaxed);
    let out = work.await;
    (count.load(Ordering::Relaxed) - before, out)
}

struct Shared {
    channels: Vec<ChannelId>,
    uploader: UserId,
}

/// One attachment posted in `count` separate channels, which is the fixture
/// the audit's finding is about: `channels_referencing_attachment` hands every
/// one of them to the permission check.
async fn one_attachment_in_many_channels(s: &Store, count: usize) -> Shared {
    s.create_role(
        "everyone",
        Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
        true,
    )
    .await
    .unwrap();
    let uploader = s.create_user("sharer", "Sharer").await.unwrap();
    let sha256 = vec![7u8; 32];
    s.store_attachment(&sha256, 8, "image/png", "shared.png", Some(uploader.id))
        .await
        .unwrap();

    let mut channels = Vec::with_capacity(count);
    for n in 0..count {
        let channel = s
            .create_channel(&format!("shared-{n}"), "text")
            .await
            .unwrap();
        s.send_message(NewMessage {
            channel_id: channel.id,
            author_id: uploader.id,
            id: MessageId::generate(),
            content: "here it is again",
            attachment_ids: std::slice::from_ref(&sha256),
            spoiler_ids: &[],
            reply_to_id: None,
            forward: None,
        })
        .await
        .unwrap();
        channels.push(channel.id);
    }
    Shared {
        channels,
        uploader: uploader.id,
    }
}

/// One send of `sha256` by someone who did not upload it, so `may_link` has to
/// reach the permission check rather than taking its uploader shortcut.
async fn forward(store: &Store, channel_id: ChannelId, author_id: UserId, sha256: &[u8]) {
    store
        .send_message(NewMessage {
            channel_id,
            author_id,
            id: MessageId::generate(),
            content: "forwarding",
            attachment_ids: std::slice::from_ref(&sha256.to_vec()),
            spoiler_ids: &[],
            reply_to_id: None,
            forward: None,
        })
        .await
        .expect("a viewer of a channel the file is in may link it");
}

/// Installs the binary's one statement counter.
fn counter() -> Arc<AtomicUsize> {
    let count = Arc::new(AtomicUsize::new(0));
    let subscriber = Registry::default().with(CountQueries(Arc::clone(&count)));
    tracing::subscriber::set_global_default(subscriber)
        .expect("no other subscriber in this binary");
    count
}

/// Three checks in sequence, sharing one counter: that the counter sees sqlx at
/// all, that `permissions_in_channels` does not spend a statement per id, and
/// that the send path behind `may_link` does not either.
#[tokio::test]
async fn permissions_in_channels_costs_the_same_whatever_its_reach() {
    let count = counter();
    let (s, _guard) = store().await;

    let (probe, _) = queries_for(&count, s.create_user("probe", "Probe")).await;
    assert!(
        probe > 0,
        "no sqlx::query events observed - the counter is not wired to sqlx, \
         and every assertion below would hold vacuously at zero"
    );

    let shared = one_attachment_in_many_channels(&s, 24).await;
    let (few, _) = queries_for(
        &count,
        s.permissions_in_channels(shared.uploader, &shared.channels[..2]),
    )
    .await;
    let (many, answers) = queries_for(
        &count,
        s.permissions_in_channels(shared.uploader, &shared.channels),
    )
    .await;
    assert_eq!(
        answers.unwrap().len(),
        24,
        "every id must still be answered"
    );
    assert!(
        many <= few + SLACK,
        "2 channels cost {few} statements and 24 cost {many}; a bounded batch \
         spends about the same either way, and the per-id loop this replaced \
         spent 22 more"
    );

    // The uploader shortcut would skip the check entirely; see `forward`.
    let stranger = s.create_user("stranger", "Stranger").await.unwrap();
    let home = s.create_channel("home", "text").await.unwrap();
    let (narrow, _) = queries_for(
        &count,
        forward(
            &s,
            home.id,
            stranger.id,
            &spread(&s, shared.uploader, 2).await,
        ),
    )
    .await;
    let wide = spread(&s, shared.uploader, 24).await;
    let (broad, _) = queries_for(&count, forward(&s, home.id, stranger.id, &wide)).await;
    assert!(
        broad <= narrow + SLACK,
        "a file on 2 channels cost {narrow} statements to link and one on 24 cost \
         {broad}; the permission check behind may_link is meant to be bounded"
    );
}

/// Room for a statement the measurement does not control - the pool opens
/// connections lazily, and a new one runs its own pragmas. Far below the 22
/// extra statements the per-id loop spent on the same comparison, which is the
/// regression this has to catch.
const SLACK: usize = 4;

/// A fresh attachment posted in `count` fresh channels, answering its sha256.
async fn spread(s: &Store, uploader: UserId, count: usize) -> Vec<u8> {
    let sha256: Vec<u8> = MessageId::generate().0.as_bytes()[..16]
        .iter()
        .chain(MessageId::generate().0.as_bytes()[..16].iter())
        .copied()
        .collect();
    s.store_attachment(&sha256, 8, "image/png", "spread.png", Some(uploader))
        .await
        .unwrap();
    for n in 0..count {
        let channel = s
            .create_channel(&format!("spread-{n}-{}", sha256[0]), "text")
            .await
            .unwrap();
        s.send_message(NewMessage {
            channel_id: channel.id,
            author_id: uploader,
            id: MessageId::generate(),
            content: "spreading",
            attachment_ids: std::slice::from_ref(&sha256),
            spoiler_ids: &[],
            reply_to_id: None,
            forward: None,
        })
        .await
        .unwrap();
    }
    assert_eq!(
        s.channels_referencing_attachment(&sha256)
            .await
            .unwrap()
            .len(),
        count,
        "the fixture must actually spread the file"
    );
    sha256
}
