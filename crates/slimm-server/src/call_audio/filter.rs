// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the server enforces on text the listener sends back: its length and
//! how fast it may arrive (decision 0104, limits).

use std::collections::VecDeque;

/// Longest segment text handed to a module.
pub const MAX_TEXT_CHARS: usize = 1_000;
/// Segments a session may deliver in any 60 seconds.
pub const MAX_PER_MINUTE: usize = 120;

/// `text` trimmed and, past [`MAX_TEXT_CHARS`], cut at a word boundary.
/// `None` when nothing is left.
pub fn cut_text(text: &str) -> Option<String> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    if text.chars().count() <= MAX_TEXT_CHARS {
        return Some(text.to_owned());
    }
    let end = text
        .char_indices()
        .nth(MAX_TEXT_CHARS)
        .map_or(text.len(), |(i, _)| i);
    let head = &text[..end];
    if text[end..].starts_with(char::is_whitespace) {
        return Some(head.trim_end().to_owned());
    }
    let cut = head.rfind(char::is_whitespace).map_or(head, |i| &head[..i]);
    Some(cut.trim_end().to_owned())
}

/// A sliding minute of arrivals, counting what it turned away.
#[derive(Default)]
pub struct SegmentRate {
    arrivals: VecDeque<i64>,
    dropped: u64,
}

impl SegmentRate {
    /// Whether a segment arriving at `now` fits; counts it as dropped when not.
    pub fn admit(&mut self, now: i64) -> bool {
        while self.arrivals.front().is_some_and(|at| now - at >= 60_000) {
            self.arrivals.pop_front();
        }
        if self.arrivals.len() >= MAX_PER_MINUTE {
            self.dropped += 1;
            return false;
        }
        self.arrivals.push_back(now);
        true
    }

    pub fn count_drop(&mut self) {
        self.dropped += 1;
    }

    #[cfg(test)]
    pub fn dropped(&self) -> u64 {
        self.dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_text_passes_trimmed_and_empty_text_is_dropped() {
        assert_eq!(cut_text("  hi there \n").as_deref(), Some("hi there"));
        assert_eq!(cut_text("   "), None);
    }

    #[test]
    fn long_text_is_cut_at_a_word_boundary() {
        let text = "word ".repeat(400);
        let cut = cut_text(&text).unwrap();
        assert!(cut.chars().count() <= MAX_TEXT_CHARS);
        assert!(
            cut.ends_with("word"),
            "cut mid-word: {}",
            &cut[cut.len() - 10..]
        );
        assert!(cut.chars().count() > MAX_TEXT_CHARS - 6);
    }

    #[test]
    fn text_with_no_spaces_is_cut_hard_on_a_character_boundary() {
        let text = "é".repeat(1_500);
        assert_eq!(cut_text(&text).unwrap().chars().count(), MAX_TEXT_CHARS);
    }

    #[test]
    fn the_rate_cap_is_a_sliding_minute_and_counts_its_drops() {
        let mut rate = SegmentRate::default();
        for i in 0..MAX_PER_MINUTE {
            assert!(rate.admit(i as i64), "{i}");
        }
        assert!(!rate.admit(1_000));
        assert!(!rate.admit(2_000));
        assert_eq!(rate.dropped(), 2);
        assert!(rate.admit(60_000), "the first arrivals aged out");
    }
}
