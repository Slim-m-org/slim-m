// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The shortcodes of the standard unicode emoji, which a custom emoji may not take.
//!
//! A client resolves a typed `:bug:` to the deployment's own image before the
//! standard glyph, so a custom `bug` would silently hide the built-in one from
//! everyone. Refusing the name keeps both reachable. The list is the client's
//! catalog (`emojis` package short names) reduced to what [`super::normalize_name`]
//! can produce, regenerated when that package moves.

use std::collections::HashSet;
use std::sync::LazyLock;

static NAMES: LazyLock<HashSet<&str>> =
    LazyLock::new(|| include_str!("builtin_names.txt").lines().collect());

/// True when `name` (already normalised) is a standard emoji's shortcode.
pub fn is_builtin_name(name: &str) -> bool {
    NAMES.contains(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_shortcodes_are_recognised_and_custom_looking_names_are_not() {
        assert!(is_builtin_name("bug"));
        assert!(is_builtin_name("fire"));
        assert!(!is_builtin_name("party_parrot"));
    }

    #[test]
    fn every_listed_name_is_one_the_normaliser_would_keep() {
        for name in NAMES.iter() {
            assert_eq!(super::super::normalize_name(name).as_deref(), Ok(*name));
        }
    }
}
