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
use slimm_server::hub::{CanvasEvent, Event, MessageEvent, RoleChange, RoleLook};
use slimm_server::ids::{
    CallRingId, CanvasObjectId, CanvasOpId, ChannelId, MessageId, RoleId, Seq, SessionId, UserId,
};
use slimm_server::notifications::NotificationPreference;
use slimm_server::permissions::Permissions;
use slimm_server::store::{ClearScope, MediaSlotKind};
use slimm_server::voice::CallRingOutcome;
use uuid::Uuid;

mod support;

use support::ws::{connect, read_frame, serve, user_ticket};

fn id(n: u128) -> Uuid {
    Uuid::from_u128(0x0190_0000_0000_7000_8000_0000_0000_0000 + n)
}

fn sample_events(channel: ChannelId, alice: UserId, bob: UserId) -> Vec<Event> {
    let message = MessageId(id(1));
    let object = CanvasObjectId(id(2));
    let op = CanvasOpId(id(3));
    vec![
        Event::Message(MessageEvent::PollVoted {
            channel_id: channel,
            message_id: message,
            options: vec![(0, 2), (1, 1)],
            runoff: None,
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
        Event::PresenceChanged(bob),
        Event::MemberTimeoutChanged {
            user_id: bob,
            until: Some(1_700_000_000_003),
        },
        Event::JoinGateChanged { user_id: Some(bob) },
        Event::MemberRemoved(UserId(id(6))),
        Event::MemberRestored(UserId(id(7))),
        Event::MemberJoined(UserId(id(8))),
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
                asked_by: alice.to_string(),
                included: vec![alice.to_string()],
                pending: vec![bob.to_string()],
                expires_at_ms: 1_700_000_000_006,
                full: false,
            })),
            ended: None,
        },
        Event::CallAudioChanged {
            channel_id: channel,
            state: None,
            ended: Some("declined"),
        },
        Event::DmChanged {
            channel_id: channel,
        },
        Event::Canvas(CanvasEvent::ObjectsRemoved {
            channel_id: channel,
            seq: Seq(4),
            op_id: op,
            object_ids: vec![object],
        }),
        Event::Canvas(CanvasEvent::Cleared {
            channel_id: channel,
            seq: Seq(5),
            op_id: op,
            before_seq: Seq(4),
            scope: ClearScope::default(),
            spared_ids: vec![object],
            spared_count: 1,
        }),
        Event::Canvas(CanvasEvent::Cleared {
            channel_id: channel,
            seq: Seq(6),
            op_id: op,
            before_seq: Seq(5),
            scope: ClearScope {
                kinds: vec!["stroke".into()],
                author_id: Some(bob),
            },
            spared_ids: vec![],
            spared_count: 0,
        }),
        Event::Canvas(CanvasEvent::ObjectsRestored {
            channel_id: channel,
            seq: Seq(7),
            op_id: op,
            object_ids: vec![object],
        }),
        Event::Canvas(CanvasEvent::CursorMoved {
            channel_id: channel,
            user_id: bob,
            x: 1.5,
            y: 2.5,
            left: false,
        }),
        Event::Canvas(CanvasEvent::StrokePreview {
            channel_id: channel,
            user_id: bob,
            object_id: object,
            points: vec![1.0, 2.0, 3.0, 4.0].into(),
            ended: false,
            cancelled: false,
            color: Some("#ff0000".into()),
            width: Some(2.0),
        }),
        Event::Canvas(CanvasEvent::ObjectPreview {
            channel_id: channel,
            user_id: bob,
            object_id: object,
            x: 1.0,
            y: 2.0,
            w: 3.0,
            h: 4.0,
            ended: true,
        }),
        Event::Canvas(CanvasEvent::MediaSlotPreview {
            channel_id: channel,
            user_id: bob,
            kind: MediaSlotKind::Screen,
            slot_user_id: alice,
            x: 1.0,
            y: 2.0,
            w: 3.0,
            h: 4.0,
            ended: false,
        }),
        Event::Canvas(CanvasEvent::View {
            channel_id: channel,
            user_id: bob,
            x: 1.0,
            y: 2.0,
            w: 3.0,
            h: 4.0,
            summon: true,
            tile: Some("tile".into()),
        }),
        Event::Canvas(CanvasEvent::ObjectMoved {
            channel_id: channel,
            seq: Seq(8),
            op_id: op,
            object_id: object,
            x: 1.0,
            y: 2.0,
            w: 3.0,
            h: 4.0,
        }),
        Event::Canvas(CanvasEvent::ObjectReordered {
            channel_id: channel,
            seq: Seq(9),
            op_id: op,
            object_id: object,
            z_index: 3,
        }),
        Event::Canvas(CanvasEvent::ObjectEdited {
            channel_id: channel,
            seq: Seq(10),
            op_id: op,
            object_id: object,
            props: "{\"a\":1}".into(),
        }),
        Event::Canvas(CanvasEvent::MediaSlotChanged {
            channel_id: channel,
            kind: MediaSlotKind::Camera,
            user_id: bob,
            x: 1.0,
            y: 2.0,
            w: 3.0,
            h: 4.0,
            locked: true,
            sent_to_back: false,
            version: 2,
        }),
        Event::Canvas(CanvasEvent::ObjectLockChanged {
            channel_id: channel,
            object_id: object,
            locked: true,
            version: 3,
        }),
        Event::ReportsChanged,
        Event::AdminAlertsChanged,
        Event::ReadStateChanged {
            user_id: alice,
            channel_id: channel,
            last_read_seq: 12,
            manually_unread: true,
        },
        Event::NotificationOverrideChanged {
            user_id: alice,
            channel_id: channel,
            preference: Some(NotificationPreference::Everything),
        },
        Event::NewDeviceSignIn {
            user_id: alice,
            device_id: slimm_server::ids::DeviceId(id(12)),
            device_name: "laptop".into(),
            client_kind: Some("linux".into()),
            signed_in_at: 1_700_000_000_005,
        },
        Event::VoiceMoved {
            user_id: alice,
            from_channel_id: channel,
            to_channel_id: ChannelId(id(13)),
            to_channel_name: "lounge".into(),
            moved_by_id: bob,
            moved_by_name: "bob".into(),
        },
        Event::VoiceNotice {
            user_id: alice,
            channel_id: channel,
            actor_id: bob,
            activity: slimm_server::voice_notify::Activity::CallStarted,
        },
        Event::VoiceSessionClosed {
            session_id: 4,
            user_id: alice,
            channel_id: channel,
            joined_at_ms: 1,
            left_at_ms: 2,
            alone_ms: 3,
        },
        Event::Stamped {
            seq: 41,
            event: Box::new(Event::MemberRemoved(UserId(id(14)))),
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

    let events = sample_events(channel, alice, bob);
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
