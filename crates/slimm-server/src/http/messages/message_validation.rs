// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounds on a message's text and its id, shared by every route that takes
//! either. Split out of [`super`] when that file reached the
//! 500-line ceiling.

use std::borrow::Cow;

use uuid::Uuid;

use crate::hidden_chars::{draws_nothing, strip_reading_rewrites};

use super::super::error::ApiError;

/// Longest a single message may be, in characters.
const MESSAGE_MAX_CHARS: usize = 4000;

/// Bounds a message's text. [`empty_ok`] is set by a send that carries
/// attachments, where the file is the message and the text is genuinely
/// optional; every other caller passes false, so the relaxation cannot spread
/// by being the default.
///
/// Controls and direction overrides are stripped first, and text that draws
/// nothing is empty, the same characters names refuse.
///
/// The over-limit reply names how far over and what the limit is, rather
/// than a bare "too long": a client composing a long paste (logs, say) needs
/// the number to trim by, not just the fact that it failed.
pub(in crate::http) fn validate_content(
    content: &str,
    empty_ok: bool,
) -> Result<Cow<'_, str>, ApiError> {
    let content = strip_reading_rewrites(content);
    if !empty_ok && draws_nothing(&content) {
        return Err(ApiError::BadRequest("message content must not be empty"));
    }
    let len = content.chars().count();
    if len > MESSAGE_MAX_CHARS {
        return Err(ApiError::BadRequestDetail(format!(
            "message is {}",
            crate::limits::chars_over_limit(len - MESSAGE_MAX_CHARS, MESSAGE_MAX_CHARS),
        )));
    }
    Ok(content)
}

pub(crate) fn parse_uuid(value: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(value).map_err(|_| ApiError::BadRequest("invalid uuid"))
}
