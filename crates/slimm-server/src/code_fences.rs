// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Finding fenced code blocks in a message body, by the same rules the client
//! renders them with (`message_fences.dart`), so block `n` here is the block
//! a viewer sees as `n`. Both sides assert against
//! `tests/fixtures/code_fence_vectors.json`; change one and the other's test
//! fails.

/// Whitespace as the client's regex engine reads `\s`, which is wider than
/// `char::is_whitespace` (it takes U+FEFF and leaves out U+0085).
fn is_fence_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202F}'
                | '\u{205F}'
                | '\u{3000}'
                | '\u{FEFF}'
    )
}

fn is_language_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '+' | '#' | '-')
}

/// The language token when `line` opens a fence, `Some("")` when unlabelled.
fn fence_open(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("```")?;
    let token_len = rest
        .char_indices()
        .find(|(_, c)| !is_language_char(*c))
        .map_or(rest.len(), |(i, _)| i);
    let (token, tail) = rest.split_at(token_len);
    tail.chars().all(is_fence_space).then_some(token)
}

fn is_fence_close(line: &str) -> bool {
    line.strip_prefix("```")
        .is_some_and(|rest| rest.chars().all(is_fence_space))
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct FencedBlock {
    pub language: Option<String>,
    pub code: String,
}

/// The fenced blocks of `lines` as (open line, close line, language token).
/// An opening fence with no closing fence after it is plain text, not a block.
fn fence_spans<'a>(lines: &[&'a str]) -> Vec<(usize, usize, &'a str)> {
    let mut spans = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        if let Some(token) = fence_open(lines[i])
            && let Some(close) = (i + 1..lines.len()).find(|&j| is_fence_close(lines[j]))
        {
            spans.push((i, close, token));
            i = close + 1;
            continue;
        }
        i += 1;
    }
    spans
}

pub(crate) fn fenced_blocks(content: &str) -> Vec<FencedBlock> {
    let lines: Vec<&str> = content.split('\n').collect();
    fence_spans(&lines)
        .into_iter()
        .map(|(open, close, token)| FencedBlock {
            language: (!token.is_empty()).then(|| token.to_string()),
            code: lines[open + 1..close].join("\n"),
        })
        .collect()
}

/// `content` with every fenced block and inline code span replaced by a space,
/// so a scan for `@name` sees only what a reader sees as prose. Inline spans
/// follow `message_inline.dart`: one pair of backticks on one line, non-empty.
pub(crate) fn prose_outside_code(content: &str) -> String {
    let lines: Vec<&str> = content.split('\n').collect();
    let mut in_fence = vec![false; lines.len()];
    for (open, close, _) in fence_spans(&lines) {
        in_fence[open..=close].fill(true);
    }
    let prose: Vec<String> = lines
        .iter()
        .zip(&in_fence)
        .filter(|(_, fenced)| !**fenced)
        .map(|(line, _)| without_inline_code(line))
        .collect();
    prose.join("\n")
}

fn without_inline_code(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(open) = rest.find('`') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find('`') {
            Some(close) if close > 0 => {
                out.push(' ');
                rest = &after[close + 1..];
            }
            _ => {
                out.push('`');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// The code of the `index`th fenced block, or `None` when there is no such block.
pub(crate) fn code_block(content: &str, index: usize) -> Option<String> {
    fenced_blocks(content)
        .into_iter()
        .nth(index)
        .map(|block| block.code)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    type Pair = (Option<String>, String);

    #[test]
    fn matches_the_shared_vectors_the_client_asserts() {
        let vectors: Vec<Value> =
            serde_json::from_str(include_str!("../tests/fixtures/code_fence_vectors.json"))
                .unwrap();
        assert!(vectors.len() >= 10);
        for v in vectors {
            let expected: Vec<Pair> = v["blocks"]
                .as_array()
                .unwrap()
                .iter()
                .map(|b| {
                    (
                        b["language"].as_str().map(str::to_string),
                        b["code"].as_str().unwrap().to_string(),
                    )
                })
                .collect();
            let got: Vec<Pair> = fenced_blocks(v["content"].as_str().unwrap())
                .into_iter()
                .map(|b| (b.language, b.code))
                .collect();
            assert_eq!(got, expected, "vector: {}", v["name"]);
        }
    }

    #[test]
    fn a_missing_index_is_none() {
        assert_eq!(code_block("```\nx\n```", 0).as_deref(), Some("x"));
        assert_eq!(code_block("```\nx\n```", 1), None);
    }
}
