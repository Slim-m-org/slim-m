// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The queries behind a member's data export: only rows the member wrote or
//! owns. Every one is keyed on `?1`, the member, and none selects another
//! person's message text; `docs/data-export-format.md` lists the result.

use super::Store;
use super::export_rows::RowStream;
use super::export_scope::{live_channel, parent_joins};
use crate::ids::UserId;

const PROFILE: &str = "SELECT id, username, display_name, pronouns, about, status_text,
        profile_color_rgb, created_at, avatar_updated_at, banner_updated_at,
        (SELECT nickname FROM member_nicknames WHERE user_id = ?1) AS nickname,
        (SELECT json_group_array(json_object('id', lower(hex(r.id)), 'name', r.name))
           FROM member_roles mr JOIN roles r ON r.id = mr.role_id
          WHERE mr.user_id = ?1 AND r.is_everyone = 0) AS roles_json
     FROM users WHERE id = ?1";

const SETTINGS: &str = "SELECT presence_visibility, notification_preference,
        push_include_content AS has_push_content,
        (SELECT json_group_array(json_object('channel_id', lower(hex(channel_id)),
                'preference', preference, 'updated_at', updated_at))
           FROM channel_notification_prefs WHERE user_id = ?1) AS channel_preferences_json,
        (SELECT json_object('timezone', s.timezone, 'off_hours_mode', s.off_hours_mode,
                'snooze_until', s.snooze_until,
                'days', (SELECT json_group_array(json_object('weekday', weekday,
                        'start_minute', start_minute, 'end_minute', end_minute))
                   FROM notification_schedule_days WHERE user_id = ?1),
                'allowed_user_ids', (SELECT json_group_array(lower(hex(allowed_user_id)))
                   FROM notification_schedule_allowed_users WHERE user_id = ?1),
                'allowed_channel_ids', (SELECT json_group_array(lower(hex(allowed_channel_id)))
                   FROM notification_schedule_allowed_channels WHERE user_id = ?1))
           FROM notification_schedules s WHERE s.user_id = ?1) AS notification_schedule_json
     FROM users WHERE id = ?1";

const LINKED: &str = "SELECT provider, external_id, username, display_name, linked_at
     FROM linked_accounts WHERE user_id = ?1 ORDER BY provider";

// A thread under a direct message reports the direct message's kind and no name.
const MESSAGES: &str = concat!(
    "SELECT m.id, m.channel_id, COALESCE(tpc.kind, c.kind) AS channel_kind,
        CASE WHEN COALESCE(tpc.kind, c.kind) = 'dm' THEN NULL ELSE c.name END AS channel_name,
        c.parent_message_id AS thread_of_message_id,
        m.seq, m.content, m.is_encrypted, m.created_at, m.edited_at, m.reply_to_id,
        (SELECT json_group_array(json_object('sha256', lower(hex(ma.sha256)),
                'filename', COALESCE(ma.filename, a.filename), 'content_type', a.content_type,
                'size', a.size,
                'spoiler', json(CASE ma.spoiler WHEN 1 THEN 'true' ELSE 'false' END),
                'included', json(CASE WHEN EXISTS (SELECT 1 FROM attachment_uploaders au
                        WHERE au.sha256 = ma.sha256 AND au.uploaded_by = ?1)
                    THEN 'true' ELSE 'false' END)))
           FROM message_attachments ma JOIN attachments a ON a.sha256 = ma.sha256
          WHERE ma.message_id = m.id) AS attachments_json,
        CASE WHEN f.message_id IS NULL THEN NULL ELSE json_object(
            'origin_message_id', lower(hex(f.origin_message_id)),
            'origin_channel_id', lower(hex(f.origin_channel_id)),
            'origin_created_at', f.origin_created_at) END AS forwarded_from_json
     FROM messages m
     JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " LEFT JOIN message_forwards f ON f.message_id = m.id
     WHERE m.author_id = ?1 AND m.deleted_at IS NULL AND ",
    live_channel!(),
    " ORDER BY m.fts_rowid"
);

const MESSAGES_COUNT: &str = concat!(
    "SELECT COUNT(*) FROM messages m
     JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " WHERE m.author_id = ?1 AND m.deleted_at IS NULL AND ",
    live_channel!()
);

const REACTIONS: &str = concat!(
    "SELECT r.message_id, m.channel_id, r.emoji, r.created_at
     FROM reactions r
     JOIN messages m ON m.id = r.message_id
     JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " WHERE r.user_id = ?1 AND m.deleted_at IS NULL AND ",
    live_channel!(),
    " ORDER BY r.message_id, r.emoji"
);

// A saved message carries its text only when the member wrote it.
const SAVED: &str = concat!(
    "SELECT s.message_id, m.channel_id, s.saved_at,
        m.author_id = ?1 AS is_own,
        CASE WHEN m.author_id = ?1 THEN m.content END AS content
     FROM saved_messages s
     JOIN messages m ON m.id = s.message_id
     JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " WHERE s.user_id = ?1 AND m.deleted_at IS NULL AND ",
    live_channel!(),
    " ORDER BY s.saved_at, s.message_id"
);

const NOTES: &str = "SELECT n.subject_id, u.username AS subject_username, n.body,
        n.created_at, n.updated_at
     FROM user_notes n JOIN users u ON u.id = n.subject_id
     WHERE n.author_id = ?1 ORDER BY n.subject_id";

const BLOCKS: &str = "SELECT b.blocked_id, u.username AS blocked_username, b.created_at
     FROM user_blocks b JOIN users u ON u.id = b.blocked_id
     WHERE b.blocker_id = ?1 ORDER BY b.blocked_id";

const POLL_VOTES: &str = concat!(
    "SELECT v.message_id, p.channel_id, v.position, v.voted_at
     FROM poll_votes v JOIN polls p ON p.message_id = v.message_id
     JOIN messages m ON m.id = v.message_id AND m.deleted_at IS NULL
     JOIN channels c ON c.id = p.channel_id ",
    parent_joins!(),
    " WHERE v.user_id = ?1 AND ",
    live_channel!(),
    " ORDER BY v.message_id"
);

const CALL_EVENTS: &str = concat!(
    "SELECT e.channel_id, e.at, e.kind FROM voice_call_events e
     JOIN channels c ON c.id = e.channel_id ",
    parent_joins!(),
    " WHERE e.user_id = ?1 AND ",
    live_channel!(),
    " ORDER BY e.at"
);

// Files the member uploaded and still has on a live message of their own.
const ATTACHMENTS: &str = concat!(
    "SELECT lower(hex(a.sha256)) AS sha256, a.size, a.content_type,
        (SELECT filename FROM attachment_uploaders
          WHERE sha256 = a.sha256 AND uploaded_by = ?1) AS filename
     FROM attachments a
     WHERE EXISTS (SELECT 1 FROM attachment_uploaders au
                    WHERE au.sha256 = a.sha256 AND au.uploaded_by = ?1)
       AND EXISTS (SELECT 1 FROM message_attachments ma
                     JOIN messages m ON m.id = ma.message_id
                     JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " WHERE ma.sha256 = a.sha256 AND m.author_id = ?1
                      AND m.deleted_at IS NULL AND ",
    live_channel!(),
    ")
     ORDER BY a.sha256"
);

const ATTACHMENTS_COUNT: &str = concat!(
    "SELECT COUNT(*) FROM attachments a
     WHERE EXISTS (SELECT 1 FROM attachment_uploaders au
                    WHERE au.sha256 = a.sha256 AND au.uploaded_by = ?1)
       AND EXISTS (SELECT 1 FROM message_attachments ma
                     JOIN messages m ON m.id = ma.message_id
                     JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " WHERE ma.sha256 = a.sha256 AND m.author_id = ?1
                      AND m.deleted_at IS NULL AND ",
    live_channel!(),
    ")"
);

/// The member's export sets, each a stream so a large account stays small in memory.
impl Store {
    pub async fn export_member_profile(
        &self,
        user: UserId,
    ) -> anyhow::Result<Option<serde_json::Value>> {
        self.one_row(PROFILE, user.0).await
    }

    pub async fn export_member_settings(
        &self,
        user: UserId,
    ) -> anyhow::Result<Option<serde_json::Value>> {
        self.one_row(SETTINGS, user.0).await
    }

    pub fn export_member_linked_accounts(&self, user: UserId) -> RowStream {
        self.stream_rows(LINKED, user.0)
    }

    pub fn export_member_messages(&self, user: UserId) -> RowStream {
        self.stream_rows(MESSAGES, user.0)
    }

    pub fn export_member_reactions(&self, user: UserId) -> RowStream {
        self.stream_rows(REACTIONS, user.0)
    }

    pub fn export_member_saved(&self, user: UserId) -> RowStream {
        self.stream_rows(SAVED, user.0)
    }

    pub fn export_member_notes(&self, user: UserId) -> RowStream {
        self.stream_rows(NOTES, user.0)
    }

    pub fn export_member_blocks(&self, user: UserId) -> RowStream {
        self.stream_rows(BLOCKS, user.0)
    }

    pub fn export_member_poll_votes(&self, user: UserId) -> RowStream {
        self.stream_rows(POLL_VOTES, user.0)
    }

    pub fn export_member_call_events(&self, user: UserId) -> RowStream {
        self.stream_rows(CALL_EVENTS, user.0)
    }

    pub fn export_member_attachments(&self, user: UserId) -> RowStream {
        self.stream_rows(ATTACHMENTS, user.0)
    }

    pub async fn export_member_counts(&self, user: UserId) -> anyhow::Result<(i64, i64)> {
        let messages = self.count_rows(MESSAGES_COUNT, user.0).await?;
        let files = self.count_rows(ATTACHMENTS_COUNT, user.0).await?;
        Ok((messages, files))
    }
}
