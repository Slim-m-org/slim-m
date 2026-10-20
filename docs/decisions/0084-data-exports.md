# 0084 - Data exports

Status: accepted, implemented
Date: 2026-10-20

## The ask

Portability is the chosen next theme (`docs/research/next-theme-2026-10.md`).
The export half comes first because it needs no owner answers: a member takes their own data out, and an administrator takes the community out in a documented format.
Guilded's shutdown is the case this answers.
A community should be able to leave with its history before it needs to.

## One archive format for both

Both exports are a single tar archive, written by a background job.
Tar is plain and streams: the writer needs only an entry's size, so attachment files are copied straight from disk, and any system can open it.
A zip would need a new dependency and a second pass for its central directory.
Entries are uncompressed, so the archive is as large as its contents, and gzip over a tar is the reader's choice.

The layout is versioned in `manifest.json` (`format_version`, now 1) and specified in `docs/data-export-format.md`.
Sections are JSON lines, one object per line, so a reader streams them as the writer did.
Adding a field is not a version change; renaming or removing one, or changing a meaning, is.

## A member's export holds only their own data

It contains the member's profile and settings, the messages they wrote, their reactions, saved message ids, private notes, blocks, poll votes, call join and leave times, linked accounts, and the files they uploaded that are still on a message of theirs.
It never contains another person's message text.
That includes the other half of a direct message: the member's own DM messages are theirs and are exported, the replies are not.
A saved message carries its text only when the member wrote it, otherwise just its id.
A reaction, a poll vote and a saved item are ids with times.
`manifest.json` lists what is not included, and the in-product copy says the same.

`tests/data_export_coverage.rs` reads the migrated schema like the account deletion coverage test does.
Every column that points at a user is either exported to a named file or excluded with a written reason, and each named file must exist in a real archive.
A new table with a user reference fails that test until someone decides.

## A space export needs ADMINISTRATOR, not MANAGE_SERVER

The space archive holds every channel's messages.
`MANAGE_SERVER` does not let its holder read a private channel, so granting it must not hand over that channel's history through the export.
`ADMINISTRATOR` already reads every channel, so the export reveals nothing the holder cannot already open.
Owner-only was rejected: a deployment has no owner column, and the first administrator is not special once others exist.

The space archive holds the space's name and settings, roles, categories, channels and threads with their overwrites, members, messages with their attachments and reaction counts, pins and custom emoji.
It never holds direct messages, deleted messages or channels, temporary voice rooms, passwords, sessions, tokens, two-factor secrets, push endpoints, invites, reports, moderation history, the audit log, canvas, polls or module data.
A deleted account is already anonymized, so its messages have no author and it is not listed as a member.

Starting a space export is written to the admin audit log as `space.export`, and each download as `space.export_download`.

## Both ask for the password

An archive is a copy of everything the account can see, so a stolen session token alone must not be able to make one.
Both starts take the account's password in the body, like issuing a reset code (decision 0048).
A bot holds no password and sends none.
A wrong password is a 403, never a 401.

## Jobs

A job is a row in `data_exports` (queued, running, ready, failed, expired) and a file named after its id.
One archive is built at a time across the server, and one export of each kind per account at a time.
A new export may start ten minutes after the last one was started; a refusal for that is a 429 with `Retry-After`.
Rows stream from SQLite one at a time into a scratch file, then the archive is written from those files and from the attachment store.
Memory use does not grow with the data, and the only extra disk is the small JSON-lines sections.
Progress counts messages and files and is written about once a second.

A finished archive can be downloaded for 24 hours, with range support so a large one resumes, and is then deleted by a sweep that also removes any file no job wants.
A server restart fails what was queued or running, since the job cannot resume.
Deleting an account removes its export rows and the sweep removes the files.
A member may delete their own export at any time, which also cancels a running one.

## Not decided here

An importer for this format is a later card.
Edit history, canvas boards, polls and module data are left out of version 1 and listed under `not_included`, so a later version can add them without breaking readers.
