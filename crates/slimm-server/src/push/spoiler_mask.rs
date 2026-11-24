// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hiding what the author hid, before a message's text is put on somebody's lock screen.
//!
//! The client renders `||text||` as a spoiler and never quotes it unmasked; a preview follows the
//! same grammar (`message_inline.dart`): a doubled bar opens, the next doubled bar closes, and
//! neither counts inside a code span or after a backslash. An unclosed opener stays literal.

use crate::hidden_chars::is_hidden_char;

const MASK: &str = "[spoiler]";

/// `text` with every spoiler span replaced by a fixed marker and hidden characters removed.
pub(super) fn mask_spoilers(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '\\' => {
                out.extend(&chars[i..(i + 2).min(chars.len())]);
                i += 2;
            }
            '`' => {
                let end = code_span_end(&chars, i);
                out.extend(&chars[i..end]);
                i = end;
            }
            '|' if chars.get(i + 1) == Some(&'|') => match closer(&chars, i + 2) {
                Some(close) => {
                    out.push_str(MASK);
                    i = close + 2;
                }
                None => {
                    out.push('|');
                    i += 1;
                }
            },
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    visible(&out)
}

fn visible(text: &str) -> String {
    text.chars()
        .filter_map(|c| match c {
            '\n' | '\r' | '\t' => Some(' '),
            c if is_hidden_char(c) => None,
            c => Some(c),
        })
        .collect()
}

/// Index just past the code span opening at `start`, or past its backtick run when none closes.
fn code_span_end(chars: &[char], start: usize) -> usize {
    let run = chars[start..].iter().take_while(|c| **c == '`').count();
    let mut j = start + run;
    while j < chars.len() {
        if chars[j] != '`' {
            j += 1;
            continue;
        }
        let len = chars[j..].iter().take_while(|c| **c == '`').count();
        if len == run {
            return j + len;
        }
        j += len;
    }
    start + run
}

/// Index of the `||` that closes a spoiler whose content starts at `from`.
fn closer(chars: &[char], from: usize) -> Option<usize> {
    let mut j = from;
    while j < chars.len() {
        match chars[j] {
            '\\' => j += 2,
            '`' => j = code_span_end(chars, j),
            '|' if chars.get(j + 1) == Some(&'|') => return Some(j),
            _ => j += 1,
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::mask_spoilers;

    #[test]
    fn a_spoiler_span_is_replaced_and_the_rest_kept() {
        assert_eq!(
            mask_spoilers("the butler ||did it|| lol"),
            "the butler [spoiler] lol"
        );
        assert_eq!(mask_spoilers("||a|| and ||b||"), "[spoiler] and [spoiler]");
    }

    #[test]
    fn an_unclosed_opener_stays_literal() {
        assert_eq!(mask_spoilers("a || b"), "a || b");
    }

    #[test]
    fn code_and_escapes_do_not_open_or_close_a_spoiler() {
        assert_eq!(mask_spoilers("`||x||` shown"), "`||x||` shown");
        assert_eq!(mask_spoilers("\\||x|| shown"), "\\||x|| shown");
        assert_eq!(mask_spoilers("||a `||` b||"), "[spoiler]");
    }

    #[test]
    fn hidden_characters_are_dropped_and_line_breaks_become_spaces() {
        assert_eq!(mask_spoilers("a\u{202E}b\nc\u{200B}d"), "ab cd");
    }
}
