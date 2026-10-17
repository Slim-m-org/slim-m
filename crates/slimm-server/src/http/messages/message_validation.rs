// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounds on a message's text and its id, shared by every route that takes
//! either. Split out of [`super`] when that file reached the
//! 500-line ceiling.

use uuid::Uuid;

use super::super::error::ApiError;

/// Longest a single message may be, in characters.
const MESSAGE_MAX_CHARS: usize = 4000;

/// Bounds a message's text. [`empty_ok`] is set by a send that carries
/// attachments, where the file is the message and the text is genuinely
/// optional; every other caller passes false, so the relaxation cannot spread
/// by being the default.
///
/// The over-limit reply names how far over and what the limit is, rather
/// than a bare "too long": a client composing a long paste (logs, say) needs
/// the number to trim by, not just the fact that it failed.
pub(in crate::http) fn validate_content(content: &str, empty_ok: bool) -> Result<&str, ApiError> {
    if !empty_ok && content.trim().is_empty() {
        return Err(ApiError::BadRequest("message content must not be empty"));
    }
    let len = content.chars().count();
    if len > MESSAGE_MAX_CHARS {
        return Err(ApiError::BadRequestDetail(format!(
            "message is {} characters over the {MESSAGE_MAX_CHARS}-character limit",
            len - MESSAGE_MAX_CHARS,
        )));
    }
    Ok(content)
}

pub(crate) fn parse_uuid(value: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(value).map_err(|_| ApiError::BadRequest("invalid uuid"))
}
