// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The two mention grammars a message body is scanned with: plain `@name`,
//! and bracketed `@[Role Name]`.
//!
//! Split out of [`super::recipients`] when that file crossed the file-budget
//! hard ceiling, along a seam that was already there: this half only reads
//! text, so it needs no store, no permissions and no async, which is why its
//! tests are plain unit tests rather than a database fixture.

use std::collections::HashSet;

/// The distinct role names inside `@[Name]` tokens in `content` - the
/// mention syntax for a role, a separate bracketed grammar rather than a
/// widened `@name` charset, for two reasons at once: it lets a role name
/// hold spaces and mixed case (`@[Core Team]`) that the plain charset in
/// [`mentioned_usernames`] cannot, and it makes a role and a user sharing a
/// name unambiguous by construction rather than by a resolution-order
/// tie-break - `@nick` is always the user, `@[nick]` is always the role.
/// Matched the identical way in `message_inline.dart`'s `parseInline`.
///
/// A name is trimmed of surrounding whitespace and dropped if that leaves it
/// empty; a `[` with no `]` before the next newline (or the end of the
/// message) is not a mention at all, and scanning resumes just past it.
pub(super) fn mentioned_role_names(content: &str) -> HashSet<String> {
    let mut names = HashSet::new();
    let mut rest = content;
    while let Some(open) = rest.find("@[") {
        if escaped_at(rest.as_bytes(), open) {
            rest = &rest[open + 2..];
            continue;
        }
        let after = &rest[open + 2..];
        match after.find(['\n', ']']) {
            Some(idx) if after.as_bytes()[idx] == b']' => {
                let name = after[..idx].trim();
                if !name.is_empty() {
                    names.insert(name.to_owned());
                }
                rest = &after[idx + 1..];
            }
            // A newline before any `]` means this was never a mention.
            Some(idx) => rest = &after[idx..],
            None => break,
        }
    }
    names
}

/// The distinct `@name` runs in `content`, over the same greedy charset
/// `message_inline.dart`'s `_mentionPattern` renders as a mention chip -
/// a word character to open, then any run of `[A-Za-z0-9_.-]` - so a push
/// reaches exactly the mentions a reader would actually see highlighted.
/// Trailing `.`/`-` are stripped from each run the same way the client's
/// `_trimMentionEnd` does: `thanks @nick.` at the end of a sentence must
/// resolve to `nick`, not `nick.`, or the mention silently fails to notify
/// anyone. The cost, also paid client-side: a username genuinely ending in
/// `.` or `-` (`validate_username` in `http/auth.rs` allows one) can never
/// be mentioned, since its trailing character always reads as punctuation.
/// Hand-rolled rather than a `regex` dependency, the same call this codebase
/// already made for its client-side markdown grammar.
pub(super) fn mentioned_usernames(content: &str) -> HashSet<String> {
    let bytes = content.as_bytes();
    let mut names = HashSet::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'@' {
            i += 1;
            continue;
        }
        let start = i + 1;
        if escaped_at(bytes, i) || start >= bytes.len() || !is_mention_start(bytes[start]) {
            i += 1;
            continue;
        }
        let mut end = start + 1;
        while end < bytes.len() && is_mention_continuation(bytes[end]) {
            end += 1;
        }
        while end > start + 1 && matches!(bytes[end - 1], b'.' | b'-') {
            end -= 1;
        }
        names.insert(content[start..end].to_owned());
        i = end;
    }
    names
}

/// Whether the `@` at `at` is escaped: preceded by an odd run of
/// backslashes, the way `message_inline.dart` reads `\@bob` as text.
fn escaped_at(bytes: &[u8], at: usize) -> bool {
    bytes[..at]
        .iter()
        .rev()
        .take_while(|&&b| b == b'\\')
        .count()
        % 2
        == 1
}

fn is_mention_start(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn is_mention_continuation(b: u8) -> bool {
    is_mention_start(b) || matches!(b, b'.' | b'-')
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{mentioned_role_names, mentioned_usernames};

    #[test]
    fn finds_a_bracketed_role_mention_with_spaces_and_mixed_case() {
        assert_eq!(
            mentioned_role_names("hey @[Core Team], any update?"),
            one("Core Team")
        );
    }

    #[test]
    fn an_unclosed_bracket_is_not_a_mention() {
        assert!(mentioned_role_names("an unclosed @[Core Team here").is_empty());
    }

    #[test]
    fn a_newline_before_the_closing_bracket_is_not_a_mention() {
        assert!(mentioned_role_names("@[Core\nTeam]").is_empty());
    }

    #[test]
    fn surrounding_whitespace_inside_the_brackets_is_trimmed() {
        assert_eq!(mentioned_role_names("@[  Core Team  ]"), one("Core Team"));
    }

    #[test]
    fn empty_brackets_are_not_a_mention() {
        assert!(mentioned_role_names("@[]").is_empty());
        assert!(mentioned_role_names("@[   ]").is_empty());
    }

    #[test]
    fn a_plain_username_mention_is_never_read_as_a_role() {
        assert!(mentioned_role_names("plain @nick is a user").is_empty());
    }

    /// Cross-checked against `crates/slimm-server/tests/fixtures/
    /// role_mention_charset_cases.json` the same way
    /// [the_shared_charset_fixture_agrees_with_message_inline_dart] cross-checks
    /// the plain `@name` grammar; see that test's own doc.
    #[test]
    fn the_shared_role_fixture_agrees_with_message_inline_dart() {
        for case in load_role_mention_cases() {
            let actual = mentioned_role_names(&case.content);
            let expected: HashSet<String> = case.mentions.into_iter().collect();
            assert_eq!(actual, expected, "content: {:?}", case.content);
        }
    }

    fn load_role_mention_cases() -> Vec<MentionCase> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/role_mention_charset_cases.json");
        let raw = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        serde_json::from_str(&raw).expect("role_mention_charset_cases.json must be valid JSON")
    }

    /// The fence vectors carry the mentions a reader sees outside code, which
    /// `message_mentions_test.dart` asserts from the client side.
    #[test]
    fn the_code_fence_vectors_agree_on_which_mentions_are_prose() {
        let vectors: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../../tests/fixtures/code_fence_vectors.json"))
                .unwrap();
        let mut checked = 0;
        for v in vectors.iter().filter(|v| v.get("mentions").is_some()) {
            let content = v["content"].as_str().unwrap();
            let expected: HashSet<String> = v["mentions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|m| m.as_str().unwrap().to_owned())
                .collect();
            let prose = crate::code_fences::prose_outside_code(content);
            assert_eq!(
                mentioned_usernames(&prose),
                expected,
                "vector: {}",
                v["name"]
            );
            checked += 1;
        }
        assert!(checked >= 8);
    }

    #[test]
    fn finds_every_distinct_mention_and_nothing_else() {
        let names = mentioned_usernames("hey @alice and @bob, cc @alice again, not an email");
        assert_eq!(names.len(), 2);
        assert!(names.contains("alice"));
        assert!(names.contains("bob"));
    }

    #[test]
    fn a_bare_at_with_nothing_after_it_is_not_a_mention() {
        assert!(mentioned_usernames("look @ this").is_empty());
        assert!(mentioned_usernames("trailing @").is_empty());
    }

    #[test]
    fn a_trailing_full_stop_is_sentence_punctuation_not_part_of_the_name() {
        assert_eq!(mentioned_usernames("thanks @nick."), one("nick"));
    }

    #[test]
    fn a_hyphen_inside_a_name_is_kept_in_full() {
        assert_eq!(mentioned_usernames("see @nick-c"), one("nick-c"));
    }

    fn one(name: &str) -> HashSet<String> {
        HashSet::from([name.to_owned()])
    }

    /// Cross-checked against the exact same cases, on the exact same input
    /// strings, in `client/packages/app/test/
    /// message_inline_mention_charset_test.dart` - editing this function's
    /// charset or trimming rule without a matching client edit fails one side
    /// of that shared table, not both.
    #[test]
    fn the_shared_charset_fixture_agrees_with_message_inline_dart() {
        for case in load_mention_cases() {
            let actual = mentioned_usernames(&case.content);
            let expected: HashSet<String> = case.mentions.into_iter().collect();
            assert_eq!(actual, expected, "content: {:?}", case.content);
        }
    }

    #[derive(serde::Deserialize)]
    struct MentionCase {
        content: String,
        mentions: Vec<String>,
    }

    fn load_mention_cases() -> Vec<MentionCase> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/mention_charset_cases.json");
        let raw = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        serde_json::from_str(&raw).expect("mention_charset_cases.json must be valid JSON")
    }
}
