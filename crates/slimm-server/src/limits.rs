// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Caps shared by more than one route, so a change lands everywhere at once
//! and the client's mirror of them has one number to follow.

/// Longest name or label: display names, nicknames, device names, channel,
/// category and role names, and webhook labels.
pub const MAX_NAME_CHARS: usize = 64;

/// Longest username; usernames are also ASCII letters, digits, `_`, `.` and `-` only.
pub const MAX_USERNAME_CHARS: usize = 32;

/// Shortest and longest password.
pub const MIN_PASSWORD_CHARS: usize = 8;
pub const MAX_PASSWORD_CHARS: usize = 1024;

/// Longest search query, for message search and the GIF picker alike.
pub const MAX_QUERY_CHARS: usize = 200;
