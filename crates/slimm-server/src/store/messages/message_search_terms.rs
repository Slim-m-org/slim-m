// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a typed search query is made of: the plain words it becomes, the
//! scripts that need a substring match, and the cost guard on raw FTS5 syntax.

/// Whether `c` belongs to a script written without spaces between words; the
/// ranges are the ones `message_trigram_ai` indexes (migration 0217).
pub(super) fn is_unsegmented(c: char) -> bool {
    matches!(c,
        '\u{3040}'..='\u{30FF}'
        | '\u{3400}'..='\u{4DBF}'
        | '\u{4E00}'..='\u{9FFF}'
        | '\u{F900}'..='\u{FAFF}'
        | '\u{1000}'..='\u{109F}'
        | '\u{0E00}'..='\u{0EFF}'
        | '\u{1780}'..='\u{17FF}'
        | '\u{20000}'..='\u{2A6DF}')
}

pub(super) fn has_unsegmented(word: &str) -> bool {
    word.chars().any(is_unsegmented)
}

/// Whether every `*` prefix term in raw FTS5 syntax has at least [`MIN_PREFIX_CHARS`]
/// base characters, and there are at most [`MAX_PREFIX_TERMS`] of them.
pub(super) fn prefix_terms_allowed(q: &str) -> bool {
    let chars: Vec<char> = q.chars().collect();
    let mut terms = 0;
    for (i, _) in chars.iter().enumerate().filter(|(_, c)| **c == '*') {
        terms += 1;
        if terms > MAX_PREFIX_TERMS {
            return false;
        }
        let before: String = chars[..i].iter().collect();
        let before = match before.trim_end().strip_suffix('"') {
            Some(_) => before.trim_end(),
            None => before.as_str(),
        };
        let last_word = match before.strip_suffix('"') {
            Some(quoted) => quoted.rsplit('"').next().unwrap_or("").to_owned(),
            None => before.to_owned(),
        };
        let word: String = last_word
            .chars()
            .rev()
            .take_while(|&c| is_word_char(c))
            .collect();
        if base_char_count(&word) < MIN_PREFIX_CHARS {
            return false;
        }
    }
    true
}

/// Whether `q` is written in FTS5's query language rather than being plain
/// words: a quote, `*`, a bracket, a column filter or an upper-case operator.
/// Lower-case `and`/`or`/`not` are words to FTS5 as well.
pub(super) fn uses_fts_syntax(q: &str) -> bool {
    q.contains(['"', '*', '(', ')', ':', '^', '+', '{', '}'])
        || q.split_whitespace()
            .any(|w| matches!(w, "AND" | "OR" | "NOT"))
}

/// Words with fewer base characters than this match whole: with no `prefix=`
/// index, `"w"*` walks every term starting with `w` in every channel.
pub(super) const MIN_PREFIX_CHARS: usize = 2;

/// Words past this many in one query match whole, so one search cannot fan out into dozens of prefix scans.
pub(super) const MAX_PREFIX_TERMS: usize = 8;

/// [q]'s words as FTS5 phrases, so text that is not query syntax still finds
/// what it names: `.iso` becomes `"iso"*`, a one-character `a` stays `"a"`.
/// Empty when no word remains.
pub(super) fn literal_fts_query(q: &str) -> String {
    plain_words(q)
        .enumerate()
        .map(|(i, w)| phrase(w, i))
        .collect::<Vec<_>>()
        .join(" ")
}

pub(super) fn plain_words(q: &str) -> impl Iterator<Item = &str> {
    q.split(|c: char| !is_word_char(c))
        .filter(|w| !w.is_empty())
}

/// `word` as a phrase, a prefix one unless it is too short or the query already has [`MAX_PREFIX_TERMS`].
pub(super) fn phrase(word: &str, index: usize) -> String {
    match base_char_count(word) < MIN_PREFIX_CHARS || index >= MAX_PREFIX_TERMS {
        true => format!("\"{word}\""),
        false => format!("\"{word}\"*"),
    }
}

/// A character FTS5's `unicode61` tokenizer keeps inside a word, including the
/// combining accents it folds away, so a decomposed `é` is not a word break.
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || is_combining_accent(c)
}

pub(super) fn base_char_count(word: &str) -> usize {
    word.chars().filter(|&c| !is_combining_accent(c)).count()
}

fn is_combining_accent(c: char) -> bool {
    ('\u{0300}'..='\u{036F}').contains(&c)
}

#[cfg(test)]
mod literal_tests {
    use super::{literal_fts_query, prefix_terms_allowed, uses_fts_syntax};

    #[test]
    fn punctuation_becomes_quoted_prefix_words() {
        assert_eq!(literal_fts_query(".iso"), "\"iso\"*");
        assert_eq!(
            literal_fts_query("ubuntu-24.04"),
            "\"ubuntu\"* \"24\"* \"04\"*"
        );
        assert_eq!(literal_fts_query("..."), "");
    }

    #[test]
    fn a_one_character_word_matches_whole_instead_of_as_a_prefix() {
        assert_eq!(literal_fts_query("a"), "\"a\"");
        assert_eq!(literal_fts_query("w 7"), "\"w\" \"7\"");
        assert_eq!(literal_fts_query("c ab"), "\"c\" \"ab\"*");
        assert_eq!(literal_fts_query("e\u{301}"), "\"e\u{301}\"");
    }

    #[test]
    fn a_combining_accent_stays_inside_its_word() {
        assert_eq!(literal_fts_query("cafe\u{301}s"), "\"cafe\u{301}s\"*");
    }

    #[test]
    fn plain_words_are_not_fts_syntax() {
        for q in [
            "Win",
            "win11 english",
            ".iso",
            "ubuntu-24.04",
            "war and peace",
            "a or b",
        ] {
            assert!(!uses_fts_syntax(q), "q={q}");
        }
    }

    #[test]
    fn quotes_stars_brackets_filters_and_operators_are_fts_syntax() {
        for q in [
            "\"quick brown\"",
            "wind*",
            "NEAR(a b)",
            "content:win",
            "^win",
            "a + b",
            "{content} : win",
            "win AND iso",
            "win OR iso",
            "win NOT iso",
        ] {
            assert!(uses_fts_syntax(q), "q={q}");
        }
    }

    #[test]
    fn a_short_or_excess_prefix_term_in_raw_syntax_is_refused() {
        for q in ["a* OR e*", "\"a b\"*", "win OR *", "NEAR(a* b)"] {
            assert!(!prefix_terms_allowed(q), "q={q}");
        }
        let flood = ["ab*"; 9].join(" OR ");
        assert!(!prefix_terms_allowed(&flood));
        for q in ["win*", "\"quick brown\"*", "a OR e", "ab* OR cd*"] {
            assert!(prefix_terms_allowed(q), "q={q}");
        }
    }

    #[test]
    fn words_past_the_prefix_cap_match_whole() {
        let q = "aa bb cc dd ee ff gg hh ii jj";
        let expected =
            "\"aa\"* \"bb\"* \"cc\"* \"dd\"* \"ee\"* \"ff\"* \"gg\"* \"hh\"* \"ii\" \"jj\"";
        assert_eq!(literal_fts_query(q), expected);
    }
}
