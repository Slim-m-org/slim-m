// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The events add-on API 5 added (decision 0107): edits, voice participants,
//! screen shares, role changes, poll tallies and who reacted.

use std::sync::Arc;

use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::http::spawn_module_events;
use slimm_server::hub::{Event, MessageEvent};
use slimm_server::ids::{ChannelId, MessageId, RoleId, UserId};
use slimm_server::presence::Visibility;
use slimm_server::store::Runoff;
use tower::ServiceExt;

mod support;
use support::module_events_world::EventModule;
use support::module_world::{World, world};
use support::wait::wait_for;
use support::wasm_fixtures::event_recorder_wasm;

const NEW_EVENTS: [&str; 7] = [
    "message.edited",
    "voice.participant.joined",
    "voice.participant.left",
    "voice.screen_share.changed",
    "member.roles.changed",
    "poll.voted",
    "reaction.changed",
];

async fn listener(w: &World) -> UserId {
    w.install_event_module(EventModule {
        id: "listener",
        wasm: event_recorder_wasm(),
        subscribes: &NEW_EVENTS,
        approved: &["events", "kv.store"],
    })
    .await
}

async fn send(w: &World, method: &str, uri: &str, body: Value) -> Value {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {}", w.token))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let response = w.router.clone().oneshot(request).await.unwrap();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

async fn recorded_of(w: &World, kind: &str, count: usize) -> Vec<Value> {
    wait_for(&format!("{count} {kind} event(s)"), || async {
        let all = w.recorded_events("listener").await;
        let of_kind: Vec<Value> = all.into_iter().filter(|e| e["event"] == kind).collect();
        (of_kind.len() >= count).then_some(of_kind)
    })
    .await
}

async fn settle() {
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
}

async fn count_of(w: &World, kind: &str) -> usize {
    let all = w.recorded_events("listener").await;
    all.iter().filter(|e| e["event"] == kind).count()
}

fn reacted(channel: ChannelId, message: MessageId, who: &[(&str, &[UserId])]) -> Event {
    let reactors = who
        .iter()
        .map(|(emoji, users)| {
            (
                (*emoji).to_owned(),
                users.iter().map(|u| (*u, 1_i64)).collect(),
            )
        })
        .collect();
    Event::Message(MessageEvent::ReactionsChanged {
        channel_id: channel,
        message_id: message,
        reactors: Arc::new(reactors),
    })
}

#[tokio::test]
async fn an_edit_arrives_with_the_new_text_and_an_own_edit_does_not() {
    let w = world("slimm-modevents-edit").await;
    let _consumer = spawn_module_events(w.state.clone());
    listener(&w).await;
    let general = w.store.create_channel("general", "text").await.unwrap();
    let id = MessageId::generate();
    let uri = format!("/channels/{}/messages", general.id);
    send(
        &w,
        "POST",
        &uri,
        json!({"id": id.to_string(), "content": "first"}),
    )
    .await;
    send(
        &w,
        "PATCH",
        &format!("{uri}/{id}"),
        json!({"content": "second"}),
    )
    .await;

    let edited = &recorded_of(&w, "message.edited", 1).await[0];
    assert!(
        edited["id"]
            .as_str()
            .unwrap()
            .starts_with(&format!("message-edit:{id}:"))
    );
    assert_eq!(edited["data"]["message_id"], json!(id.to_string()));
    assert_eq!(edited["data"]["channel_id"], json!(general.id.to_string()));
    assert_eq!(edited["data"]["author_id"], json!(w.user.id.to_string()));
    assert_eq!(edited["data"]["content"], json!("second"));
    assert_eq!(edited["data"]["is_bot"], json!(false));
    assert_eq!(edited["data"]["edited_at_ms"], edited["at_ms"]);
    assert_eq!(edited["$slim"], json!("event/1"));
}

#[tokio::test]
async fn voice_events_name_the_participant_and_skip_a_hidden_one() {
    let w = world("slimm-modevents-voice").await;
    let _consumer = spawn_module_events(w.state.clone());
    listener(&w).await;
    let room = w.store.create_channel("room", "voice").await.unwrap();
    let visible = w.store.create_user("vis", "Vis").await.unwrap().id;
    let hidden = w.store.create_user("hid", "Hid").await.unwrap().id;
    w.store
        .set_presence_visibility(hidden, Visibility::Hidden)
        .await
        .unwrap();

    let voice = |user| Event::VoiceParticipantJoined {
        channel_id: room.id,
        user_id: user,
    };
    w.hub.publish(voice(hidden));
    w.hub.publish(Event::VoiceScreenShareChanged {
        channel_id: room.id,
        user_id: hidden,
        is_sharing_screen: true,
    });
    w.hub.publish(voice(visible));
    w.hub.publish(Event::VoiceScreenShareChanged {
        channel_id: room.id,
        user_id: visible,
        is_sharing_screen: true,
    });
    w.hub.publish(Event::VoiceParticipantLeft {
        channel_id: room.id,
        user_id: visible,
    });

    let joined = &recorded_of(&w, "voice.participant.joined", 1).await[0];
    assert_eq!(
        joined["data"],
        json!({"channel_id": room.id.to_string(), "user_id": visible.to_string()})
    );
    let shared = &recorded_of(&w, "voice.screen_share.changed", 1).await[0];
    assert_eq!(
        shared["data"],
        json!({"channel_id": room.id.to_string(), "user_id": visible.to_string(), "sharing": true})
    );
    let left = &recorded_of(&w, "voice.participant.left", 1).await[0];
    assert_eq!(left["data"]["user_id"], json!(visible.to_string()));
    settle().await;
    assert_eq!(count_of(&w, "voice.participant.joined").await, 1);
    assert_eq!(count_of(&w, "voice.screen_share.changed").await, 1);
}

#[tokio::test]
async fn a_role_change_names_the_member_the_role_and_the_direction() {
    let w = world("slimm-modevents-roles").await;
    let _consumer = spawn_module_events(w.state.clone());
    listener(&w).await;
    let (member, role) = (UserId::generate(), RoleId::generate());
    for granted in [true, false] {
        w.hub.publish(Event::MemberRoleChanged {
            user_id: member,
            role_id: role,
            granted,
            role_name: Some("Mods".to_owned()),
        });
    }
    let seen = recorded_of(&w, "member.roles.changed", 2).await;
    let data = |granted| {
        json!({"user_id": member.to_string(), "role_id": role.to_string(),
               "granted": granted, "role_name": "Mods"})
    };
    assert_eq!(seen[0]["data"], data(true));
    assert_eq!(seen[1]["data"], data(false));
}

#[tokio::test]
async fn a_poll_vote_carries_the_tally_and_no_voter() {
    let w = world("slimm-modevents-poll").await;
    let _consumer = spawn_module_events(w.state.clone());
    listener(&w).await;
    let general = w.store.create_channel("general", "text").await.unwrap();
    let message = MessageId::generate();
    let vote = |runoff| {
        Event::Message(MessageEvent::PollVoted {
            channel_id: general.id,
            message_id: message,
            options: vec![(0, 2), (1, 1)],
            runoff,
        })
    };
    w.hub.publish(vote(None));
    w.hub.publish(vote(Some(Runoff {
        rounds: vec![],
        winner: Some(0),
    })));

    let seen = recorded_of(&w, "poll.voted", 2).await;
    let base = |ranked: bool, winner: Value| {
        json!({"message_id": message.to_string(), "channel_id": general.id.to_string(),
            "options": [{"position": 0, "votes": 2}, {"position": 1, "votes": 1}],
            "ranked": ranked, "winner": winner})
    };
    assert_eq!(seen[0]["data"], base(false, Value::Null));
    assert_eq!(seen[1]["data"], base(true, json!(0)));
}

#[tokio::test]
async fn a_reaction_names_who_moved_and_a_blocked_reactor_is_not_heard() {
    let w = world("slimm-modevents-reactor").await;
    let _consumer = spawn_module_events(w.state.clone());
    let bot = listener(&w).await;
    let general = w.store.create_channel("general", "text").await.unwrap();
    let message = MessageId::generate();
    let ann = w.store.create_user("ann", "Ann").await.unwrap().id;
    let bob = w.store.create_user("bob", "Bob").await.unwrap().id;
    w.store.block_user(bot, bob).await.unwrap();

    w.hub
        .publish(reacted(general.id, message, &[("a", &[ann])]));
    w.hub
        .publish(reacted(general.id, message, &[("a", &[ann, bob])]));
    w.hub
        .publish(reacted(general.id, message, &[("a", &[ann])]));
    w.hub.publish(reacted(general.id, message, &[]));

    let seen = recorded_of(&w, "reaction.changed", 2).await;
    settle().await;
    let seen = if seen.len() == 2 {
        seen
    } else {
        recorded_of(&w, "reaction.changed", 2).await
    };
    let moves: Vec<(String, bool, i64)> = seen
        .iter()
        .map(|e| {
            (
                e["data"]["user_id"].as_str().unwrap().to_owned(),
                e["data"]["added"].as_bool().unwrap(),
                e["data"]["count"].as_i64().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        moves,
        vec![(ann.to_string(), true, 1), (ann.to_string(), false, 0)]
    );
    assert_eq!(seen[0]["data"]["emoji"], json!("a"));
}
