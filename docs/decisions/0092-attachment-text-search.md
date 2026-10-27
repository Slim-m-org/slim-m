# 0092 - Searching text inside attachments

Status: accepted
Date: 2026-10-26

## Decision

Message search also matches text extracted from attachments.
Scope for now is text and code files and the text layer of PDFs.
There is no OCR; the owner wants that as its own module.

## Shape

- A background sweep (`attachment_text.rs`) finds attachments in live, unencrypted messages that have no `attachment_text` row, newest first, and extracts one file at a time.
  New uploads and the backfill of old ones are the same code path, so nothing runs on the upload or send path.
- Extracted text lives only in `attachment_text_fts`, an FTS5 table keyed by `attachment_text.fts_rowid`.
  A trigger removes the index row when the attachment row goes, including through the orphan sweep's cascade.
- `search_messages` matches a message by its own text or by an attachment's text.
  Channel scoping is unchanged, because the attachment match is a predicate on messages already limited to the channels the caller may read.
- A hit found only through an attachment carries `matched_attachment_id`, and the client says "Found in <file>".

## Bounds

The server runs in about 512 MiB, so every step is capped:

- at most 1 MiB is read from a text file, and a PDF over 8 MiB is skipped;
- at most 100 PDF pages are visited and 100,000 characters stored per attachment;
- files are handled one at a time with a short pause, at most 200 per pass, and a PDF parses on a blocking thread under a 20 second timeout;
- an encrypted, malformed or scanned PDF yields no text and is recorded as processed, so it is not retried.

## PDF crate

`lopdf` 0.42.0 with default features off.
It is MIT, pure Rust and maintained.
0.41 and earlier abort the process on a deeply nested PDF (RUSTSEC-2026-0187), which cannot be caught, so 0.42 is the floor.
0.43 to 0.46 need `cipher` 0.5 final, which conflicts with the `=0.5.0-rc.1` pin `crypto_secretbox` holds, so 0.42.0 is the only version that resolves today.
Revisit when that pin moves.
It pulls `ttf-parser`, which carries an unmaintained advisory; nothing here touches fonts.
