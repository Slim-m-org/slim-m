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
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_message_event_carries_exactly_the_documented_fields() {
        let event = ModuleEvent {
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
            json!({"event":"message.created","id":"message:m1","at_ms":5,"data":{
                "message_id":"m1","channel_id":"c1","author_id":"u1","content":"hi",
                "created_at_ms":5,"is_bot":false}})
        );
    }
}
