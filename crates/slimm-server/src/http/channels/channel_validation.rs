// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a channel's name, topic and `join_muted` may be, on create and update.

use super::super::error::ApiError;
use super::super::hidden_chars::is_hidden_char;

/// A one-line header, not a description field: long enough for a real
/// sentence, short enough that a client never needs to wrap or truncate it
/// in the channel header it's designed for.
const CHANNEL_TOPIC_MAX_CHARS: usize = 256;

/// Normalizes a topic edit. A blank (or whitespace-only) value clears the
/// topic back to `None` rather than being stored as an empty string: a topic
/// with nothing visible in it is not meaningfully different from having
/// none, and folding the two together means a single `Option<String>` field
/// can carry "clear it" without a separate tri-state signal.
pub(in crate::http) fn validate_channel_topic(topic: &str) -> Result<Option<String>, ApiError> {
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

pub(in crate::http) const JOIN_MUTED_VOICE_ONLY: &str =
    "join_muted only applies to a voice channel";
pub(in crate::http) const ROOMS_VOICE_ONLY: &str =
    "creates_rooms and user_limit only apply to a voice channel, and a room cannot make rooms";

/// The largest user limit a voice channel takes.
pub(in crate::http) const MAX_USER_LIMIT: i64 = 99;

pub(in crate::http) fn validate_user_limit(limit: i64) -> Result<i64, ApiError> {
    if !(0..=MAX_USER_LIMIT).contains(&limit) {
        return Err(ApiError::BadRequest("user_limit must be 0 to 99"));
    }
    Ok(limit)
}

pub(in crate::http) fn validate_channel_name(name: &str) -> Result<&str, ApiError> {
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
