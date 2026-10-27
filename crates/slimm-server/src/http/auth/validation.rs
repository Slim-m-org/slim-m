// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Credential and display-name validation shared with bot provisioning, `/me` and password reset.

use crate::http::error::ApiError;

/// `everyone` and `here` are reserved, case-insensitively, so `@everyone` and
/// `@here` (`push::recipients::resolved_mentions`) can never collide with a
/// real account - a plain username-shaped word would otherwise be
/// ambiguous between "the reserved mention" and "the person who registered
/// it first".
const RESERVED_USERNAMES: [&str; 2] = ["everyone", "here"];

/// Shared with bot provisioning, so a bot name cannot claim a reserved
/// mention or a character class a person's username could never hold.
pub(crate) fn validate_username(username: &str) -> Result<(), ApiError> {
    let len = username.chars().count();
    if !(1..=crate::limits::MAX_USERNAME_CHARS).contains(&len) {
        return Err(ApiError::BadRequest("username must be 1 to 32 characters"));
    }
    let allowed = username
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'));
    if !allowed {
        return Err(ApiError::BadRequest(
            "username may contain only letters, digits, and _ . -",
        ));
    }
    if RESERVED_USERNAMES.contains(&username.to_ascii_lowercase().as_str()) {
        return Err(ApiError::BadRequest(
            "that username is reserved for @everyone/@here mentions",
        ));
    }
    Ok(())
}

/// Cross-checked in this module's own tests against `tests/fixtures/
/// onboarding_error_strings.json`, the fixture the client's onboarding
/// snapshot tests also read, so this exact wording cannot drift from the
/// fixture text a reviewer sees in a screenshot.
pub(super) const PASSWORD_LENGTH_MESSAGE: &str = "password must be 8 to 1024 characters";

/// Shared with the reset-password consumption endpoint, so a reset cannot be
/// used to set a weaker password than registration would ever allow.
pub(crate) fn validate_password(password: &str) -> Result<(), ApiError> {
    let len = password.chars().count();
    if !(crate::limits::MIN_PASSWORD_CHARS..=crate::limits::MAX_PASSWORD_CHARS).contains(&len) {
        return Err(ApiError::BadRequest(PASSWORD_LENGTH_MESSAGE));
    }
    Ok(())
}

/// Shared with the display-name-only update on `/me`, so a later rename
/// cannot bypass the same anti-spoofing checks registration enforces up
/// front.
pub(crate) fn validate_label(value: &str, message: &'static str) -> Result<(), ApiError> {
    let len = value.chars().count();
    if !(1..=crate::limits::MAX_NAME_CHARS).contains(&len) {
        return Err(ApiError::BadRequest(message));
    }
    if value.trim().is_empty() {
        return Err(ApiError::BadRequest("name must not be blank"));
    }
    if value.chars().any(is_disallowed_label_char) {
        return Err(ApiError::BadRequest(
            "name must not contain control or text-direction characters",
        ));
    }
    Ok(())
}

/// The label blocklist is the shared hidden-character set, under the name its
/// callers already use, so a name and a status line refuse what a message does.
pub(crate) use crate::hidden_chars::is_hidden_char as is_disallowed_label_char;
