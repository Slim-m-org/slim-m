// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pins the wire frame each id-only hub event serialises to, so reshaping the
//! `Event` enum cannot move a byte on the socket.
//!
//! Regenerate the golden with `UPDATE_GOLDEN=1` only for an intended wire change.

use std::path::Path;
use std::time::Duration;

use serde_json::Value;
use std::sync::Arc;

use slimm_server::call_audio::CallAudioView;
use slimm_server::hub::{
    CastBallot, Event, MessageEvent, ModuleRoomChange, RoleChange, RoleLook, RoomJson,
};
use slimm_server::ids::{CallRingId, ChannelId, MessageId, RoleId, SessionId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::voice::CallRingOutcome;
use uuid::Uuid;

use super::ws_event_frame_samples::more_events;
use crate::support;
use support::ws::{connect, read_frame, serve, user_ticket};

pub fn id(n: u128) -> Uuid {
    Uuid::from_u128(0x0190_0000_0000_7000_8000_0000_0000_0000 + n)
}

fn sample_events(channel: ChannelId, alice: UserId, bob: UserId) -> Vec<Event> {
    let message = MessageId(id(1));
    vec![
        Event::Message(MessageEvent::PollVoted {
            channel_id: channel,
            message_id: message,
            options: vec![(0, 2), (1, 1)],
            runoff: None,
            version: 41,
            cast: Some(Arc::new(CastBallot {
                user_id: alice,
                ranking: vec![1],
            })),
        }),
        Event::Message(MessageEvent::ComponentsChanged {
            channel_id: channel,
            message_id: message,
            components: Default::default(),
        }),
        Event::Message(MessageEvent::EmbedsChanged {
            channel_id: channel,
            message_id: message,
            embeds: Default::default(),
        }),
        Event::Message(MessageEvent::LinkPreviewsRemoved {
            channel_id: channel,
            message_id: message,
            op_seq: 7,
        }),
        Event::Message(MessageEvent::Deleted {
            channel_id: channel,
            message_id: message,
            op_seq: Some(8),
        }),
        Event::Message(MessageEvent::ReactionsChanged {
            channel_id: channel,
            message_id: message,
            reactors: Default::default(),
            moved: None,
            version: 42,
        }),
        Event::Message(MessageEvent::CodeRunChanged {
            channel_id: channel,
            message_id: message,
            block_index: 0,
            module_id: "runner".into(),
            command: "run".into(),
            ok: true,
            output: "hello".into(),
            ran_by: Some(alice),
            ran_at: 1_700_000_000_000,
        }),
        Event::Message(MessageEvent::CodeRunsCleared {
            channel_id: channel,
            message_id: message,
        }),
        Event::Message(MessageEvent::ThreadUpdated {
            channel_id: channel,
            parent_message_id: message,
            thread_channel_id: ChannelId(id(4)),
            reply_count: 3,
            last_reply_at: Some(1_700_000_000_001),
        }),
        Event::Message(MessageEvent::Pinned {
            channel_id: channel,
            message_id: message,
            pinned_by: Some(alice),
            pinned_at: 1_700_000_000_002,
        }),
        Event::Message(MessageEvent::Unpinned {
            channel_id: channel,
            message_id: message,
        }),
        Event::SessionRevoked(SessionId(id(5))),
        Event::presence_changed(bob),
        Event::MemberTimeoutChanged {
            user_id: bob,
            until: Some(1_700_000_000_003),
        },
        Event::JoinGateChanged { user_id: Some(bob) },
        Event::MemberRemoved {
            user_id: UserId(id(6)),
            deleted: false,
        },
        Event::MemberRestored(UserId(id(7))),
        Event::MemberJoined(UserId(id(8))),
        Event::OwnerChanged(bob),
        Event::ProfileChanged(bob),
        Event::BotUiChanged(bob),
        Event::TypingStarted {
            channel_id: channel,
            user_id: bob,
        },
        Event::TypingStopped {
            channel_id: channel,
            user_id: bob,
        },
        Event::RoleChanged {
            role_id: RoleId(id(9)),
            change: None,
        },
        Event::RoleChanged {
            role_id: RoleId(id(9)),
            change: Some(Arc::new(RoleChange::Updated {
                before: RoleLook {
                    name: "Mods".into(),
                    color: None,
                    hoist: false,
                    mentionable: false,
                },
                after: RoleLook {
                    name: "Moderators".into(),
                    color: Some(3),
                    hoist: true,
                    mentionable: false,
                },
            })),
        },
        Event::MemberRoleChanged {
            user_id: bob,
            role_id: RoleId(id(9)),
            granted: true,
            role_name: Some("Moderators".into()),
        },
        Event::ChannelDeleted {
            channel_id: ChannelId(id(10)),
        },
        Event::CategoryChanged,
        Event::SpaceSettingsChanged,
        Event::SpaceThemesChanged,
        Event::OverwriteChanged {
            channel_id: channel,
            previously_visible_to: Default::default(),
        },
        Event::VoiceActivityChanged {
            channel_id: channel,
        },
        Event::VoiceParticipantJoined {
            channel_id: channel,
            user_id: bob,
        },
        Event::VoiceParticipantLeft {
            channel_id: channel,
            user_id: bob,
        },
        Event::WatchTick {
            channel_id: channel,
            bot_user_id: bob,
            ended: false,
            item_id: "item".into(),
            playing: true,
            position_ms: 1500,
            sampled_at_ms: 1_700_000_000_004,
            epoch: 2,
        },
        Event::VoiceScreenShareChanged {
            channel_id: channel,
            user_id: bob,
            is_sharing_screen: true,
        },
        Event::CallRinging {
            channel_id: channel,
            ring_id: CallRingId(id(11)),
            caller_id: bob,
            callees: Arc::from([alice]),
        },
        Event::CallRingEnded {
            channel_id: channel,
            ring_id: CallRingId(id(11)),
            outcome: CallRingOutcome::Declined,
        },
        Event::CallAudioChanged {
            channel_id: channel,
            state: Some(Box::new(CallAudioView {
                module_id: "hearer".into(),
                module_name: "Hearer".into(),
                purpose: "Writes down what is said.".into(),
                keeps: "The text, for 30 days.".into(),
                status: "asking",
                asked_by: Some(alice.to_string()),
                included: vec![alice.to_string()],
                pending: vec![bob.to_string()],
                expires_at_ms: 1_700_000_000_006,
                full: false,
                mode: None,
                transcript_id: None,
                transcript: false,
                automatic: false,
            })),
            ended: None,
        },
        Event::CallAudioChanged {
            channel_id: channel,
            state: None,
            ended: Some("declined"),
        },
        Event::ModuleRoomChanged(Arc::new(ModuleRoomChange {
            channel_id: channel,
            module_id: "noughts".into(),
            seq: 3,
            state: Some(RoomJson::new(
                serde_json::value::RawValue::from_string(r#"{"board":"x...o...."}"#.into())
                    .unwrap(),
            )),
            scene: Some(RoomJson::new(
                serde_json::value::RawValue::from_string(r#"{"$slim":"scene/1"}"#.into()).unwrap(),
            )),
            ended: None,
        })),
        Event::ModuleRoomChanged(Arc::new(ModuleRoomChange {
            channel_id: channel,
            module_id: "noughts".into(),
            seq: 3,
            state: None,
            scene: None,
            ended: Some("call_ended"),
        })),
        Event::CallTranscriptChanged {
            channel_id: channel,
            transcript_id: slimm_server::ids::CallTranscriptId(id(12)),
            ended: true,
        },
        Event::CallTranscriptLine {
            channel_id: channel,
            transcript_id: slimm_server::ids::CallTranscriptId(id(12)),
            audience: vec![alice].into(),
            line: Arc::new(slimm_server::store::TranscriptLine {
                seq: 3,
                speaker_id: bob,
                at: 1_700_000_000_007,
                end_at: Some(1_700_000_000_009),
                language: Some("en".into()),
                text: "hello".into(),
            }),
        },
    ]
}

fn normalised(frame: &Value, names: &[(String, &str)]) -> String {
    let mut frame = frame.clone();
    // A moderation seq is minted from the clock, so only its presence is stable.
    if frame["seq"]
        .as_i64()
        .is_some_and(|seq| seq > 1_000_000_000_000)
    {
        frame["seq"] = Value::from("CLOCK");
    }
    let mut text = frame.to_string();
    for (real, stand_in) in names {
        text = text.replace(real.as_str(), stand_in);
    }
    text
}

#[tokio::test]
async fn id_only_events_keep_their_wire_frames() {
    let (store, _guard) = support::new_store("slimm-ws-event-frame-pin").await;
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let state = support::app::state(store.clone());
    let (_, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_, _, bob) = user_ticket(&store, "bob").await;
    store.assign_role(alice, role).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap().id;
    let addr = serve(state.clone()).await;
    let mut ws = connect(addr, &alice_ticket).await;

    let mut events = sample_events(channel, alice, bob);
    events.extend(more_events(channel, alice, bob));
    for event in events {
        state.hub.publish(event);
    }

    let names = [
        (channel.to_string(), "CHANNEL"),
        (alice.to_string(), "ALICE"),
        (bob.to_string(), "BOB"),
    ];
    let mut seen = Vec::new();
    while let Ok(frame) =
        tokio::time::timeout(Duration::from_millis(1500), read_frame(&mut ws)).await
    {
        if frame["type"] != "presence.changed" {
            seen.push(normalised(&frame, &names));
        }
    }
    seen.sort();
    let pinned = serde_json::to_string_pretty(&seen).unwrap() + "\n";

    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/ws_event_frames.json");
    if std::env::var_os("UPDATE_GOLDEN").is_some() {
        std::fs::write(&path, &pinned).unwrap();
    }
    let golden = std::fs::read_to_string(&path).expect("golden file");
    assert_eq!(pinned, golden);
}
