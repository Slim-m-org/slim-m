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

/// How far a value runs past its cap, as a refusal says it: "3 characters
/// over the 4000-character limit", singular for one.
pub fn chars_over_limit(over: usize, max: usize) -> String {
    let unit = if over == 1 { "character" } else { "characters" };
    format!("{over} {unit} over the {max}-character limit")
}

#[cfg(test)]
mod tests {
    use super::chars_over_limit;

    #[test]
    fn one_character_over_is_singular() {
        assert_eq!(
            chars_over_limit(1, 64),
            "1 character over the 64-character limit"
        );
        assert_eq!(
            chars_over_limit(2, 64),
            "2 characters over the 64-character limit"
        );
    }
}
