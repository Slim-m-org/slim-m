# Data export format

What a slim-m export archive holds, for anyone reading one or writing an importer.
The reasoning is in [decision 0084](decisions/0084-data-exports.md).
Format name `slimm-export`, version 1.

## Container

An archive is one uncompressed ustar tar file, named `slimm-<kind>-export-<unix seconds>.tar`.
Entry names are at most 100 bytes and use `/`.
Entries over 8 GiB use the GNU base-256 size field, which GNU tar and bsdtar read.
Entry order is fixed: `manifest.json`, `README.txt`, the sections in the order the manifest lists them, then `attachments/<sha256>` for each indexed file, then `report.json`.
Read `manifest.json` first.

## Rules for readers

- `.jsonl` files hold one JSON object per line, UTF-8, with no blank lines. An empty file means none, not unknown.
- Ids are UUIDs as lowercase hyphenated strings. Times are unix milliseconds.
- Unknown fields must be ignored. A new field is not a version change.
- A different `format_version` than the one a reader knows must be refused, not guessed at.
- `kind` is `member` or `space`.

## manifest.json

| Field | Meaning |
| --- | --- |
| `format` | Always `slimm-export`. |
| `format_version` | Integer, 1 today. |
| `kind` | `member` or `space`. |
| `created_at` | When the archive was started. |
| `server_version` | The server that wrote it. |
| `files` | Every section: `path`, `format` (`json`, `jsonl` or `binary`), `rows` (a count for `jsonl`, else null) and a one-line `description`. |
| `attachments` | `index` (`attachments.jsonl`) and `directory` (`attachments/`). |
| `not_included` | Plain-language list of what the archive deliberately leaves out. |
| `subject_user_id` | Member exports only: the account the archive belongs to. |
| `space_name` | Space exports only. |

## report.json

`attachments_missing`: sha256 ids the index named whose file had vanished from storage when the archive was written, at most 1000.
The archive is otherwise complete.

## Attachments

`attachments.jsonl` has one row per distinct file: `sha256` (lowercase hex), `size`, `content_type`, `filename`, and in a space export `created_at`.
Its bytes are `attachments/<sha256>`.
The sha256 is the identity: a message names its files by it.
Files are the stored copy.
When a space keeps originals beside compressed copies, the original is not exported.

## Message rows

Common fields: `id`, `seq` (order within a channel), `content`, `is_encrypted`, `created_at`, `edited_at` (null if never edited), `reply_to_id`, `attachments` (array of `sha256`, `filename`, `content_type`, `size`, `spoiler`).
Only the current text is exported, never edit history.
Deleted messages are never exported.

## Member export (`kind: member`)

| File | Rows |
| --- | --- |
| `profile.json` | `id`, `username`, `display_name`, `pronouns`, `about`, `status_text`, `profile_color_rgb`, `created_at`, `avatar_updated_at`, `banner_updated_at`, `nickname`, `roles` (`id`, `name`). |
| `settings.json` | `presence_visibility`, `notification_preference`, `has_push_content`, `channel_preferences`, `notification_schedule` (timezone, off-hours mode, snooze, days, allowed members and channels). |
| `linked_accounts.jsonl` | `provider`, `external_id`, `username`, `display_name`, `linked_at`. |
| `messages.jsonl` | The member's own messages, with `channel_id`, `channel_kind` (`text`, `voice` or `dm`), `channel_name` (null for a direct message), `thread_of_message_id`, and `forwarded_from` (ids and time only, no text). |
| `reactions.jsonl` | `message_id`, `channel_id`, `emoji`, `created_at`. |
| `saved.jsonl` | `message_id`, `channel_id`, `saved_at`, `is_own`, and `content` only when `is_own`. |
| `notes.jsonl` | The member's private notes: `subject_id`, `subject_username`, `body`, times. |
| `blocks.jsonl` | `blocked_id`, `blocked_username`, `created_at`. |
| `poll_votes.jsonl` | `message_id`, `channel_id`, `position`, `voted_at`. |
| `call_events.jsonl` | `channel_id`, `at`, `kind` (`joined`, `left`, `share_started`, `share_stopped`). |
| `profile/avatar`, `profile/banner` | The member's own images, when set. |

Never in a member export: other people's messages (including the other side of a direct message), the text of saved messages somebody else wrote, deleted messages, anything in a deleted channel, credentials, sessions, devices, reports, canvas content and anything a moderator did.

## Space export (`kind: space`)

| File | Rows |
| --- | --- |
| `space.json` | `name`, `description`, `join_policy`, `message_retention_days`, `rules_text`, `welcome_message`, `has_welcome`, `icon_updated_at`, `banner_updated_at`. |
| `roles.jsonl` | `id`, `name`, `permissions` (bitmask), `position`, `is_everyone`, `mentionable`, `hoist`, `color`, `created_at`. |
| `categories.jsonl` | `id`, `name`, `position`, `created_at`. |
| `channels.jsonl` | `id`, `name`, `kind`, `topic`, `position`, `category_id`, `thread_of_message_id`, `slow_mode_seconds`, `default_notification`, `overwrites` (`target_type` `role` or `member`, `target_id`, `allow`, `deny`). |
| `members.jsonl` | `id`, `username`, `display_name`, `is_bot`, `is_webhook`, `created_at`, `nickname`, `role_ids`. |
| `channels/<channel id>/messages.jsonl` | The channel's or thread's messages, oldest first, with `author_id` (null once the author deleted their account), `reactions` (`emoji`, `count`) and `forwarded_from`. Channels with no messages have no file. |
| `pins.jsonl` | `channel_id`, `message_id`, `pinned_by`, `pinned_at`. |
| `emoji.jsonl` | `id`, `name`, `sha256`, `uploader_id`, `created_at`. |
| `space/icon`, `space/banner` | The space images, when set. |

Never in a space export: direct messages, deleted messages or channels, temporary voice rooms, password hashes, sessions, access or bot tokens, two-factor secrets, push endpoints, invites, reports, moderation history, the admin audit log, canvas boards, polls and module data.

## Lifetime

A finished archive can be downloaded for 24 hours and is then deleted.
A member export needs the account's password to start, a space export needs ADMINISTRATOR and the password.
