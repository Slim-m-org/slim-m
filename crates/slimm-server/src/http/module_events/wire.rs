// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The module-facing event shapes of decision 0091. Purpose-built, so a field
//! added to a websocket frame or a hub event never reaches a module by accident.

use serde::Serialize;

/// What a module reads as its run's input text.
#[derive(Serialize)]
pub(super) struct ModuleEvent<'a> {
    pub(super) event: &'a str,
    pub(super) id: String,
    pub(super) at_ms: i64,
    pub(super) data: EventData,
    /// Last, so the fields a module already finds at fixed offsets stay where they were.
    #[serde(rename = "$slim")]
    pub(super) contract: String,
}

/// One poll option's running total; never who voted for it.
#[derive(Serialize)]
pub(super) struct PollOptionCount {
    pub(super) position: i64,
    pub(super) votes: i64,
}

#[derive(Serialize)]
/// Untagged: the event's name travels beside it, so the data holds only its fields.
#[serde(untagged)]
pub(super) enum EventData {
    MessageCreated {
        message_id: String,
        channel_id: String,
        author_id: Option<String>,
        content: String,
        created_at_ms: i64,
        is_bot: bool,
    },
    MessageDeleted {
        message_id: String,
        channel_id: String,
    },
    ReactionChanged {
        message_id: String,
        channel_id: String,
        emoji: String,
        count: i64,
        user_id: String,
        added: bool,
    },
    MessageEdited {
        message_id: String,
        channel_id: String,
        author_id: Option<String>,
        content: String,
        edited_at_ms: i64,
        is_bot: bool,
    },
    VoiceParticipant {
        channel_id: String,
        user_id: String,
    },
    VoiceScreenShare {
        channel_id: String,
        user_id: String,
        sharing: bool,
    },
    MemberRoles {
        user_id: String,
        role_id: String,
        granted: bool,
        role_name: Option<String>,
    },
    PollVoted {
        message_id: String,
        channel_id: String,
        options: Vec<PollOptionCount>,
        ranked: bool,
        winner: Option<i64>,
    },
    Member {
        user_id: String,
    },
    VoiceSessionClosed {
        session_id: i64,
        user_id: String,
        channel_id: String,
        joined_at_ms: i64,
        left_at_ms: i64,
        alone_ms: i64,
    },
    CallAudioStarted {
        session_id: String,
        channel_id: String,
        started_at_ms: i64,
        included: Vec<String>,
    },
    CallAudioParticipant {
        session_id: String,
        channel_id: String,
        user_id: String,
        included: bool,
    },
    CallAudioSegment {
        session_id: String,
        channel_id: String,
        segment_id: String,
        user_id: String,
        start_ms: i64,
        end_ms: i64,
        text: String,
        language: Option<String>,
    },
    CallAudioStopped {
        session_id: String,
        channel_id: String,
        stopped_at_ms: i64,
        reason: &'static str,
        segments_sent: u64,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The documented fixtures under `docs/modules/event-fixtures` are what a module author tests against, so each must be exactly what the host sends.
    fn fixture(name: &str) -> serde_json::Value {
        let path = format!(
            "{}/../../docs/modules/event-fixtures/{name}.json",
            env!("CARGO_MANIFEST_DIR")
        );
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn sent(event: &'static str, id: &str, at_ms: i64, data: EventData) -> serde_json::Value {
        serde_json::to_value(ModuleEvent {
            contract: "event/1".into(),
            event,
            id: id.to_owned(),
            at_ms,
            data,
        })
        .unwrap()
    }

    const U1: &str = "01a1a929-1736-71c0-939f-664b6d5fb270";
    const U2: &str = "01a1a929-1736-71c0-939f-664b6d5fb271";
    const C: &str = "01a1a929-1827-7e11-b45f-fa8008c5ac06";
    const M: &str = "01a1a929-1827-7e11-b45f-fa9aa9f12513";
    const R: &str = "01a1a929-1827-7e11-b45f-fa9aa9f12514";

    #[test]
    fn the_fixtures_for_the_level_5_events_are_what_the_host_sends() {
        let participant = || EventData::VoiceParticipant {
            channel_id: C.into(),
            user_id: U1.into(),
        };
        let cases = [
            sent(
                "message.edited",
                &format!("message-edit:{M}:7"),
                1_760_000_300_000,
                EventData::MessageEdited {
                    message_id: M.into(),
                    channel_id: C.into(),
                    author_id: Some(U1.into()),
                    content: "the edited text".into(),
                    edited_at_ms: 1_760_000_300_000,
                    is_bot: false,
                },
            ),
            sent(
                "voice.participant.joined",
                &format!("voice-join:{U1}:1760000000000"),
                1_760_000_000_000,
                participant(),
            ),
            sent(
                "voice.participant.left",
                &format!("voice-leave:{U1}:1760000600000"),
                1_760_000_600_000,
                participant(),
            ),
            sent(
                "voice.screen_share.changed",
                &format!("voice-share:{U1}:1760000100000"),
                1_760_000_100_000,
                EventData::VoiceScreenShare {
                    channel_id: C.into(),
                    user_id: U1.into(),
                    sharing: true,
                },
            ),
            sent(
                "member.roles.changed",
                &format!("member-roles:{U1}:{R}:1760000200000"),
                1_760_000_200_000,
                EventData::MemberRoles {
                    user_id: U1.into(),
                    role_id: R.into(),
                    granted: true,
                    role_name: Some("Mods".into()),
                },
            ),
            sent(
                "poll.voted",
                &format!("poll-vote:{M}:1760000400000"),
                1_760_000_400_000,
                EventData::PollVoted {
                    message_id: M.into(),
                    channel_id: C.into(),
                    options: vec![
                        PollOptionCount {
                            position: 0,
                            votes: 2,
                        },
                        PollOptionCount {
                            position: 1,
                            votes: 1,
                        },
                    ],
                    ranked: false,
                    winner: None,
                },
            ),
            sent(
                "reaction.changed",
                &format!("reaction:{M}:thumbs-up:1760000500000:{U2}"),
                1_760_000_500_000,
                EventData::ReactionChanged {
                    message_id: M.into(),
                    channel_id: C.into(),
                    emoji: "thumbs-up".into(),
                    count: 3,
                    user_id: U2.into(),
                    added: true,
                },
            ),
        ];
        for case in cases {
            let name = case["event"].as_str().unwrap().to_owned();
            assert_eq!(case, fixture(&name), "{name}");
        }
    }

    #[test]
    fn a_call_audio_segment_carries_exactly_the_documented_fields() {
        let event = ModuleEvent {
            contract: "event/1".into(),
            event: "call.audio.segment",
            id: "call-audio:s:3".into(),
            at_ms: 9,
            data: EventData::CallAudioSegment {
                session_id: "s".into(),
                channel_id: "c".into(),
                segment_id: "call-audio:s:3".into(),
                user_id: "u".into(),
                start_ms: 1,
                end_ms: 2,
                text: "hi".into(),
                language: Some("en".into()),
            },
        };
        assert_eq!(
            serde_json::to_value(&event).unwrap()["data"],
            json!({"session_id":"s","channel_id":"c","segment_id":"call-audio:s:3",
                "user_id":"u","start_ms":1,"end_ms":2,"text":"hi","language":"en"})
        );
    }

    #[test]
    fn a_stopped_event_names_a_reason_and_never_a_person() {
        let data = EventData::CallAudioStopped {
            session_id: "s".into(),
            channel_id: "c".into(),
            stopped_at_ms: 4,
            reason: "declined",
            segments_sent: 7,
        };
        assert_eq!(
            serde_json::to_value(&data).unwrap(),
            json!({"session_id":"s","channel_id":"c","stopped_at_ms":4,
                "reason":"declined","segments_sent":7})
        );
    }

    #[test]
    fn a_message_event_carries_exactly_the_documented_fields() {
        let event = ModuleEvent {
            contract: "event/1".into(),
            event: "message.created",
            id: "message:m1".into(),
            at_ms: 5,
            data: EventData::MessageCreated {
                message_id: "m1".into(),
                channel_id: "c1".into(),
                author_id: Some("u1".into()),
                content: "hi".into(),
                created_at_ms: 5,
                is_bot: false,
            },
        };
        assert_eq!(
            serde_json::to_value(&event).unwrap(),
            json!({"$slim":"event/1","event":"message.created","id":"message:m1","at_ms":5,"data":{
                "message_id":"m1","channel_id":"c1","author_id":"u1","content":"hi",
                "created_at_ms":5,"is_bot":false}})
        );
    }
}
