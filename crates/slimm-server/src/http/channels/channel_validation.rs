// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a channel's name, topic and `join_muted` and default notification level may be, on create and update.

use super::super::error::ApiError;
use super::super::hidden_chars::{draws_nothing, is_hidden_char};
use crate::notifications::NotificationPreference;
use crate::store::{CANVAS_CHANNEL_KIND, TEXT_CHANNEL_KIND, VOICE_CHANNEL_KIND};

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

pub(in crate::http) const CANVAS_FLAG_VOICE_ONLY: &str = "canvas_enabled is for voice channels";
pub(in crate::http) const VOICE_FLAG_CANVAS_ONLY: &str = "voice_enabled is for canvas channels";

/// The per-kind settings a create request names, as the client sent them.
pub(in crate::http) struct CreateFlags {
    pub join_muted: Option<bool>,
    pub creates_rooms: Option<bool>,
    pub canvas_enabled: Option<bool>,
    pub voice_enabled: Option<bool>,
}

/// Checks the kind and refuses each per-kind flag on a kind it does not belong to.
///
/// Only `true` is refused: `false` is the wrong kind's own state, so a client can send its whole form.
pub(in crate::http) fn validate_create_kind(
    kind: &str,
    flags: &CreateFlags,
) -> Result<(), ApiError> {
    if !matches!(
        kind,
        TEXT_CHANNEL_KIND | VOICE_CHANNEL_KIND | CANVAS_CHANNEL_KIND
    ) {
        return Err(ApiError::BadRequest("kind must be text, voice or canvas"));
    }
    if flags.join_muted == Some(true) && kind != VOICE_CHANNEL_KIND {
        return Err(ApiError::BadRequest(JOIN_MUTED_VOICE_ONLY));
    }
    if flags.creates_rooms == Some(true) && kind != VOICE_CHANNEL_KIND {
        return Err(ApiError::BadRequest(ROOMS_VOICE_ONLY));
    }
    if flags.canvas_enabled == Some(true) && kind != VOICE_CHANNEL_KIND {
        return Err(ApiError::BadRequest(CANVAS_FLAG_VOICE_ONLY));
    }
    if flags.voice_enabled == Some(true) && kind != CANVAS_CHANNEL_KIND {
        return Err(ApiError::BadRequest(VOICE_FLAG_CANVAS_ONLY));
    }
    Ok(())
}

/// A voice channel made without the field keeps its board, as it always had (decision 0139); a canvas channel's call is opt-in.
pub(in crate::http) fn canvas_enabled_at_create(kind: &str, requested: Option<bool>) -> bool {
    kind == VOICE_CHANNEL_KIND && requested != Some(false)
}

pub(in crate::http) fn voice_enabled_at_create(kind: &str, requested: Option<bool>) -> bool {
    kind == CANVAS_CHANNEL_KIND && requested == Some(true)
}

/// Parses a channel's default notification level; `everything` means no default.
pub(in crate::http) fn validate_default_notification(
    value: &str,
) -> Result<NotificationPreference, ApiError> {
    NotificationPreference::parse(value).ok_or(ApiError::BadRequest(
        "default_notification must be everything, mentions or nothing",
    ))
}

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
    if draws_nothing(trimmed) {
        return Err(ApiError::BadRequest("name must not be blank"));
    }
    Ok(trimmed)
}
