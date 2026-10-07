// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Code points in [text] once trimmed, the unit the server's length limits use.
///
/// Not `String.length` (utf-16 units) and not graphemes: Rust's `chars().count()` counts code points.
int trimmedCharCount(String text) => text.trim().runes.length;
