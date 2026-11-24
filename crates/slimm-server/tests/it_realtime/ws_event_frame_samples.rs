// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The second half of the hub events `ws_event_frame_pin` publishes.

use std::sync::Arc;

use slimm_server::hub::{CanvasEvent, ConnectorRunRequest, Event, RoomJson, VoiceRemovalReason};
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, Seq, UserId};
use slimm_server::notifications::NotificationPreference;
use slimm_server::store::{ClearScope, MediaSlotKind};
use uuid::Uuid;

fn id(n: u128) -> Uuid {
    super::ws_event_frame_pin::id(n)
}

pub fn more_events(channel: ChannelId, alice: UserId, bob: UserId) -> Vec<Event> {
    let object = CanvasObjectId(id(2));
    let op = CanvasOpId(id(3));
    vec![
        Event::CallTranscriptMarkChanged {
            channel_id: channel,
            transcript_id: slimm_server::ids::CallTranscriptId(id(12)),
            mark_id: slimm_server::ids::CallTranscriptMarkId(id(13)),
            mark: Some(Arc::new(slimm_server::store::TranscriptMark {
                id: slimm_server::ids::CallTranscriptMarkId(id(13)),
                transcript_id: slimm_server::ids::CallTranscriptId(id(12)),
                author_id: bob,
                at: 1_700_000_000_008,
                line_seq: Some(3),
                kind: slimm_server::store::MarkKind::Note,
                text: Some("follow up".into()),
                source: slimm_server::store::MarkSource::Manual,
            })),
            audience: vec![alice].into(),
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
        Event::Canvas(CanvasEvent::TileSceneChanged {
            channel_id: channel,
            object_id: object,
            output: Arc::from("{\"$slim\":\"scene/1\"}"),
            ran_by: Some(bob),
            ran_at: 9,
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
        Event::CategoryMuteChanged {
            user_id: alice,
            category_id: slimm_server::ids::ChannelCategoryId(id(20)),
            muted: true,
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
        Event::VoiceRemoved {
            user_id: alice,
            channel_id: channel,
            reason: VoiceRemovalReason::OtherDevice,
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
        Event::ConnectorRun(Arc::new(ConnectorRunRequest {
            principal: alice,
            run_id: id(21),
            module_id: "pelican".into(),
            deadline_ms: 6000,
            request: RoomJson::new(
                serde_json::value::RawValue::from_string(
                    r#"{"command":"servers","input":""}"#.into(),
                )
                .unwrap(),
            ),
        })),
        Event::ConnectorRun(Arc::new(ConnectorRunRequest {
            principal: bob,
            run_id: id(22),
            module_id: "pelican".into(),
            deadline_ms: 6000,
            request: RoomJson::new(
                serde_json::value::RawValue::from_string(r#"{"withheld":true}"#.into()).unwrap(),
            ),
        })),
        Event::Stamped {
            seq: 41,
            event: Box::new(Event::MemberRemoved {
                user_id: UserId(id(14)),
                deleted: false,
            }),
        },
        Event::MemberRemoved {
            user_id: UserId(id(23)),
            deleted: true,
        },
    ]
}
