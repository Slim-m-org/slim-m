// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What everyone else is told when an account is deleted: the reaction and
//! poll counts it changed, its profile, and the rooms that carried its name.

use axum::http::StatusCode;
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{Ballot, NewMessage, NewPoll, Store};
use tower::ServiceExt;

use crate::support;
use support::app::request_authed;

struct World {
    store: Store,
    admin_token: String,
    leaver: UserId,
    channel: ChannelId,
}

async fn world(store: Store) -> World {
    let admin = store.create_account("root", "Root", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let leaver = store.create_account("ben", "Ben", "x").await.unwrap();
    World {
        admin_token: store
            .open_session(admin.id, "cli")
            .await
            .unwrap()
            .access_token,
        channel: store.list_channels().await.unwrap()[0].id,
        leaver: leaver.id,
        store,
    }
}

/// Deletes the leaver as the administrator and returns every event published.
async fn delete_and_collect(w: &World) -> Vec<Event> {
    let hub = Hub::new();
    let app = support::app::builder(w.store.clone())
        .hub(hub.clone())
        .router();
    let mut rx = hub.subscribe();
    let response = app
        .oneshot(request_authed(
            "DELETE",
            &format!("/members/{}/account", w.leaver),
            &w.admin_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let mut events = Vec::new();
    while let Ok(event) = rx.try_recv() {
        events.push(match event {
            Event::Stamped { event, .. } => *event,
            other => other,
        });
    }
    events
}

#[tokio::test]
async fn deleting_an_account_announces_the_reactions_it_took() {
    let (store, _guard) = support::new_store("slimm-deletion-reaction-events").await;
    let w = world(store).await;
    let message = MessageId::generate();
    w.store
        .send_message(NewMessage::plain(w.channel, w.leaver, message, "hi"))
        .await
        .unwrap();
    w.store
        .add_reaction(message, w.leaver, "\u{1F44D}")
        .await
        .unwrap();

    let events = delete_and_collect(&w).await;

    let announced = events.iter().any(|e| {
        matches!(e, Event::Message(MessageEvent::ReactionsChanged { message_id, reactors, .. })
            if *message_id == message && reactors.is_empty())
    });
    assert!(
        announced,
        "no emptied ReactionsChanged for the message: {events:?}"
    );
}

#[tokio::test]
async fn deleting_an_account_announces_the_poll_votes_it_took() {
    let (store, _guard) = support::new_store("slimm-deletion-poll-events").await;
    let w = world(store).await;
    let poll = MessageId::generate();
    w.store
        .send_poll_message(
            w.channel,
            w.leaver,
            poll,
            "vote",
            NewPoll {
                question: "lunch?",
                options: &["yes".into(), "no".into()],
                close_at: None,
                ranked: false,
            },
            None,
        )
        .await
        .unwrap();
    w.store
        .vote_poll(poll, w.leaver, Ballot::Single(0))
        .await
        .unwrap();

    let events = delete_and_collect(&w).await;

    let tally = events.iter().find_map(|e| match e {
        Event::Message(MessageEvent::PollVoted {
            message_id,
            options,
            ..
        }) if *message_id == poll => Some(options.clone()),
        _ => None,
    });
    assert_eq!(tally, Some(vec![(0, 0), (1, 0)]), "events: {events:?}");
}

#[tokio::test]
async fn deleting_an_account_tells_clients_to_rehydrate_its_author_label() {
    let (store, _guard) = support::new_store("slimm-deletion-profile-event").await;
    let w = world(store).await;

    let events = delete_and_collect(&w).await;

    assert!(
        events
            .iter()
            .any(|e| matches!(e, Event::ProfileChanged(id) if *id == w.leaver)),
        "no ProfileChanged for the deleted account: {events:?}"
    );
}

#[tokio::test]
async fn deleting_an_account_renames_and_releases_its_temporary_room() {
    let (store, _guard) = support::new_store("slimm-deletion-room").await;
    let w = world(store).await;
    let lobby = w.store.create_channel("lobby", "voice").await.unwrap();
    let room = w
        .store
        .create_voice_room(&lobby, w.leaver, "Ben's room")
        .await
        .unwrap();

    let events = delete_and_collect(&w).await;

    let kept = w
        .store
        .channel(room.id)
        .await
        .unwrap()
        .expect("the room stays");
    assert_eq!(kept.name, "Voice room");
    assert_eq!(kept.room.owner_id, None);
    let announced = events.iter().any(|e| {
        matches!(e, Event::ChannelUpdated(channel, _)
            if channel.id == room.id && channel.name == "Voice room")
    });
    assert!(announced, "no ChannelUpdated for the room: {events:?}");
}
