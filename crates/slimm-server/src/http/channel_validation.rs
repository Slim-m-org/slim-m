// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a channel's name, topic and `join_muted` may be, on create and update.

use super::error::ApiError;
use super::hidden_chars::is_hidden_char;

/// A one-line header, not a description field: long enough for a real
/// sentence, short enough that a client never needs to wrap or truncate it
/// in the channel header it's designed for.
const CHANNEL_TOPIC_MAX_CHARS: usize = 256;

/// Normalizes a topic edit. A blank (or whitespace-only) value clears the
/// topic back to `None` rather than being stored as an empty string: a topic
/// with nothing visible in it is not meaningfully different from having
/// none, and folding the two together means a single `Option<String>` field
/// can carry "clear it" without a separate tri-state signal.
pub(super) fn validate_channel_topic(topic: &str) -> Result<Option<String>, ApiError> {
    let trimmed = topic.trim();
    if trimmed.chars().count() > CHANNEL_TOPIC_MAX_CHARS {
        return Err(ApiError::BadRequest("topic must be at most 256 characters"));
    }
    if trimmed.chars().any(is_hidden_char) {
        return Err(ApiError::BadRequest(
            "topic must not contain control or invisible characters",
        ));
    }
    Ok(if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    })
}

pub(super) const JOIN_MUTED_VOICE_ONLY: &str = "join_muted only applies to a voice channel";

pub(super) fn validate_channel_name(name: &str) -> Result<&str, ApiError> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.chars().count() > crate::limits::MAX_NAME_CHARS {
        return Err(ApiError::BadRequest("name must be 1 to 64 characters"));
    }
    if trimmed.chars().any(is_hidden_char) {
        return Err(ApiError::BadRequest(
            "name must not contain control or invisible characters",
        ));
    }
    Ok(trimmed)
}
