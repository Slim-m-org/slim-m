// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a connected user says they are doing right now: listening to a track
//! or playing a game.
//!
//! Ephemeral like the rest of presence (decision 0044): it lives on the
//! user's [`crate::presence::PresenceTracker`] entry, so it disappears with
//! their last socket and is never written to SQLite.

use serde::{Deserialize, Serialize};

/// Longest title or subtitle, in characters. The client truncates to the same
/// number, so a well-behaved sender never sees the refusal.
pub const MAX_TEXT_CHARS: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
/// Serialised lowercase, matching the OpenAPI enum.
#[serde(rename_all = "snake_case")]
pub enum ActivityKind {
    Listening,
    Playing,
}

/// Longest `source` label, in characters ("Spotify", "Firefox").
pub const MAX_SOURCE_CHARS: usize = 32;

const ART_PREFIX: &str = "https://i.scdn.co/image/";
const ART_ID_LEN: usize = 40;

/// True only for a Spotify cover URL of exactly the shape the CDN serves:
/// no other host, port, userinfo, query or fragment can ride in (decision
/// 0056), because every viewer's client will fetch it.
pub fn is_allowed_art_url(url: &str) -> bool {
    url.strip_prefix(ART_PREFIX).is_some_and(|id| {
        id.len() == ART_ID_LEN && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    })
}

/// One activity as it goes over the wire.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Unknown fields are refused; the only image is `art_url`, checked by
/// [`is_allowed_art_url`].
#[serde(deny_unknown_fields)]
pub struct Activity {
    #[serde(rename = "type")]
    pub kind: ActivityKind,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    /// Epoch milliseconds the activity began, when the source knows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<i64>,
    /// Which player reported it, so a browser tab is not read as Spotify.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    /// Cover art on Spotify's CDN, the one host viewers are allowed to fetch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub art_url: Option<String>,
}

impl Activity {
    /// Refuses an empty, over-long or hidden-character text rather than
    /// trimming it, so what viewers read is exactly what the sender sent.
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.title.trim().is_empty() {
            return Err("activity title must not be empty");
        }
        let subtitle = self.subtitle.as_deref().unwrap_or("");
        for text in [self.title.as_str(), subtitle] {
            if text.chars().count() > MAX_TEXT_CHARS {
                return Err("activity text is too long");
            }
            if text.chars().any(crate::hidden_chars::is_hidden_char) {
                return Err("activity text must not contain control characters");
            }
        }
        self.validate_source()?;
        match self.art_url.as_deref() {
            Some(url) if !is_allowed_art_url(url) => Err("activity art must be a Spotify cover"),
            _ => Ok(()),
        }
    }

    fn validate_source(&self) -> Result<(), &'static str> {
        let Some(source) = self.source.as_deref() else {
            return Ok(());
        };
        if source.trim().is_empty() {
            return Err("activity source must not be empty");
        }
        if source.chars().count() > MAX_SOURCE_CHARS {
            return Err("activity source is too long");
        }
        if source.chars().any(crate::hidden_chars::is_hidden_char) {
            return Err("activity source must not contain control characters");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(title: &str) -> Activity {
        Activity {
            kind: ActivityKind::Listening,
            title: title.to_owned(),
            subtitle: None,
            started_at: None,
            source: None,
            art_url: None,
        }
    }

    #[test]
    fn source_is_capped_and_refuses_hidden_text() {
        let with = |source: &str| Activity {
            source: Some(source.to_owned()),
            ..sample("t")
        };
        assert!(with("Spotify").validate().is_ok());
        assert!(with(&"s".repeat(MAX_SOURCE_CHARS)).validate().is_ok());
        assert!(with(&"s".repeat(MAX_SOURCE_CHARS + 1)).validate().is_err());
        assert!(with(" ").validate().is_err());
        assert!(with("a\u{202e}b").validate().is_err());
    }

    #[test]
    fn art_must_be_exactly_a_spotify_cover() {
        let id = "ab67616d0000b273bc2dd68b840b1d4b7c9e5ad9";
        assert!(is_allowed_art_url(&format!("https://i.scdn.co/image/{id}")));
        for url in [
            format!("http://i.scdn.co/image/{id}"),
            format!("https://i.scdn.co/image/{id}/"),
            format!("https://i.scdn.co/image/{id}?a=b"),
            format!("https://i.scdn.co/image/{id}#f"),
            format!("https://u@i.scdn.co/image/{id}"),
            format!("https://i.scdn.co:444/image/{id}"),
            format!("https://i.scdn.co.evil.example/image/{id}"),
            format!("https://i.scdn.co/image/{}", id.to_uppercase()),
            format!("https://i.scdn.co/other/{id}"),
            format!("https://i.scdn.co/image/{}", &id[1..]),
            format!("https://I.scdn.co/image/{id}"),
        ] {
            assert!(!is_allowed_art_url(&url), "{url}");
        }
    }

    #[test]
    fn accepts_the_cap_and_refuses_one_past_it() {
        assert!(sample(&"a".repeat(MAX_TEXT_CHARS)).validate().is_ok());
        assert!(sample(&"a".repeat(MAX_TEXT_CHARS + 1)).validate().is_err());
    }

    #[test]
    fn counts_characters_not_bytes() {
        assert!(sample(&"\u{e9}".repeat(MAX_TEXT_CHARS)).validate().is_ok());
    }

    #[test]
    fn refuses_empty_control_and_direction_text() {
        assert!(sample("  ").validate().is_err());
        assert!(sample("a\nb").validate().is_err());
        assert!(sample("a\u{202e}b").validate().is_err());
        // These three were accepted while this file kept a list of its own.
        for mark in ['\u{061C}', '\u{2060}', '\u{FEFF}'] {
            assert!(sample(&format!("a{mark}b")).validate().is_err(), "{mark:?}");
        }
    }
}
