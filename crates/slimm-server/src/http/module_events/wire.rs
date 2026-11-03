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
