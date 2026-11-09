// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The comment, string and char-literal scrubber the source-reading gates share.
//!
//! Allowed dead: `mod.rs` pulls this module into every integration test
//! binary via `mod support;`, and only the source-reading gates call it.
#![allow(dead_code)]

use std::path::{Path, PathBuf};

/// Every `.rs` file under `dir`, nested folders included, in path order.
pub fn rust_files_under(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![dir.to_path_buf()];
    while let Some(folder) = pending.pop() {
        let entries = std::fs::read_dir(&folder)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", folder.display()));
        for entry in entries {
            let path = entry.expect("readable dir entry").path();
            if path.is_dir() {
                pending.push(path);
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                found.push(path);
            }
        }
    }
    found.sort();
    found
}

/// Blanks `//` and `/* */` comments (nested ones too), `"..."`/raw-string
/// (`r"..."`, `r#"..."#`, ...) literals and char/byte literals (`'"'`, `b'\''`)
/// to spaces, keeping every byte's position, so a brace count over the result
/// only ever sees real code.
///
/// A stray unmatched `}` inside an ordinary `//` comment - "think of this
/// like a code block }" is enough - closed a naive brace-depth scan the
/// moment it appeared, hiding a real second `.fetch_all(`/`&self.pool`
/// call placed after it in the actual function; reproduced directly,
/// independently, against both `canvas_index.rs`'s and
/// `thread_reply_count.rs`'s own former private copies of this logic
/// before this shared one replaced them. Raw strings need their own
/// handling because this crate's own SQL literals (`r#"SELECT ..."#`) are
/// exactly that shape.
pub fn code_only(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut out = vec![b' '; bytes.len()];
    let mut i = 0usize;
    while i < bytes.len() {
        if let Some(end) = raw_string_end(bytes, i) {
            keep_newlines(bytes, &mut out, i, end);
            i = end.max(i + 1);
            continue;
        }
        if bytes[i] == b'"' {
            let end = plain_string_end(bytes, i);
            keep_newlines(bytes, &mut out, i, end);
            i = end;
            continue;
        }
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'/') {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'*') {
            let end = block_comment_end(bytes, i);
            keep_newlines(bytes, &mut out, i, end);
            i = end;
            continue;
        }
        if bytes[i] == b'\''
            && let Some(end) = char_literal_end(bytes, i)
        {
            i = end;
            continue;
        }
        out[i] = bytes[i];
        i += 1;
    }
    String::from_utf8(out)
        .expect("only ever ASCII space/newline or original bytes, so always valid utf-8")
}

/// Keeps the line breaks of `bytes[from..to]` in `out`, so line numbers survive blanking.
fn keep_newlines(bytes: &[u8], out: &mut [u8], from: usize, to: usize) {
    for idx in from..to {
        if bytes[idx] == b'\n' {
            out[idx] = b'\n';
        }
    }
}

/// The end of the raw string (`r"..."`, `r#"..."#`, ...) starting at `i`, if one does.
fn raw_string_end(bytes: &[u8], i: usize) -> Option<usize> {
    if bytes[i] != b'r' {
        return None;
    }
    let mut hashes = 0usize;
    let mut j = i + 1;
    while j < bytes.len() && bytes[j] == b'#' {
        hashes += 1;
        j += 1;
    }
    if j >= bytes.len() || bytes[j] != b'"' {
        return None;
    }
    let close: Vec<u8> = std::iter::once(b'"')
        .chain(std::iter::repeat_n(b'#', hashes))
        .collect();
    let mut k = j + 1;
    while k < bytes.len() && bytes[k..].get(..close.len()) != Some(close.as_slice()) {
        k += 1;
    }
    Some((k + close.len()).min(bytes.len()))
}

fn plain_string_end(bytes: &[u8], i: usize) -> usize {
    let mut k = i + 1;
    while k < bytes.len() && bytes[k] != b'"' {
        k += if bytes[k] == b'\\' { 2 } else { 1 };
    }
    (k + 1).min(bytes.len())
}

/// The end of the block comment starting at `i`; Rust block comments nest.
fn block_comment_end(bytes: &[u8], i: usize) -> usize {
    let mut depth = 1usize;
    let mut k = i + 2;
    while k < bytes.len() && depth > 0 {
        match bytes.get(k..k + 2) {
            Some(b"/*") => {
                depth += 1;
                k += 2;
            }
            Some(b"*/") => {
                depth -= 1;
                k += 2;
            }
            _ => k += 1,
        }
    }
    k.min(bytes.len())
}

/// The end of the char or byte literal (`'x'`, `'\n'`, `'"'`) whose opening quote is at `i`.
///
/// `None` for a lifetime or loop label, which has no closing quote.
fn char_literal_end(bytes: &[u8], i: usize) -> Option<usize> {
    let first = *bytes.get(i + 1)?;
    if first == b'\\' {
        let close = bytes
            .get(i + 3..)?
            .iter()
            .take_while(|&&b| b != b'\n')
            .position(|&b| b == b'\'')?;
        return Some(i + 3 + close + 1);
    }
    let width = match first {
        0..=0x7F => 1,
        0xC0..=0xDF => 2,
        0xE0..=0xEF => 3,
        _ => 4,
    };
    let close = i + 1 + width;
    (first != b'\'' && bytes.get(close) == Some(&b'\'')).then_some(close + 1)
}
