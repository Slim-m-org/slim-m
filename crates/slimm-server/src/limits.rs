// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Caps shared by more than one route, so a change lands everywhere at once
//! and the client's mirror of them has one number to follow.

/// Longest name or label: display names, nicknames, device names, channel,
/// category and role names, and webhook labels.
pub const MAX_NAME_CHARS: usize = 64;

/// Longest search query, for message search and the GIF picker alike.
pub const MAX_QUERY_CHARS: usize = 200;
