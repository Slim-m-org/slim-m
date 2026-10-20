// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The queries behind a space export. Direct messages, tombstoned accounts,
//! deleted messages and deleted channels never match, and no query selects a
//! password hash, token, second-factor secret or push endpoint.

use uuid::Uuid;

use super::Store;
use super::export_rows::RowStream;
use super::export_scope::{community_channel, parent_joins};

const SPACE: &str = "SELECT s.description, s.join_policy, s.message_retention_days,
        s.rules_text, s.welcome_message,
        s.welcome_enabled AS has_welcome, s.icon_updated_at, s.banner_updated_at
     FROM space_settings s WHERE s.id = 1 AND ?1 IS NOT NULL";

const ROLES: &str = "SELECT id, name, permissions, position, is_everyone, mentionable, hoist,
        color, created_at
     FROM roles WHERE ?1 IS NOT NULL ORDER BY position DESC, id";

const CATEGORIES: &str = "SELECT id, name, position, created_at FROM channel_categories
     WHERE deleted_at IS NULL AND ?1 IS NOT NULL ORDER BY position, id";

// Temporary voice rooms and direct messages are not part of the community.
const CHANNELS: &str = concat!(
    "SELECT c.id, c.name, c.kind, c.topic, c.position, c.created_at,
        c.parent_message_id AS thread_of_message_id, c.category_id, c.slow_mode_seconds,
        c.default_notification,
        (SELECT json_group_array(json_object('target_type', o.target_type,
                'target_id', lower(hex(o.target_id)), 'allow', o.allow, 'deny', o.deny))
           FROM channel_overwrites o WHERE o.channel_id = c.id) AS overwrites_json
     FROM channels c ",
    parent_joins!(),
    " WHERE ",
    community_channel!(),
    " AND ?1 IS NOT NULL
     ORDER BY c.position, c.id"
);

const MEMBERS: &str = "SELECT u.id, u.username, u.display_name, u.is_bot AS is_bot,
        u.is_webhook AS is_webhook, u.created_at,
        (SELECT nickname FROM member_nicknames WHERE user_id = u.id) AS nickname,
        (SELECT json_group_array(lower(hex(mr.role_id))) FROM member_roles mr
          WHERE mr.user_id = u.id) AS role_ids_json
     FROM users u WHERE u.deleted_at IS NULL AND ?1 IS NOT NULL ORDER BY u.id";

// ?1 is the channel; a deleted account's author is already null.
const MESSAGES: &str = "SELECT m.id, m.seq, m.author_id, m.content, m.is_encrypted, m.created_at,
        m.edited_at, m.reply_to_id,
        (SELECT json_group_array(json_object('sha256', lower(hex(ma.sha256)),
                'filename', COALESCE(ma.filename, a.filename), 'content_type', a.content_type,
                'size', a.size,
                'spoiler', json(CASE ma.spoiler WHEN 1 THEN 'true' ELSE 'false' END)))
           FROM message_attachments ma JOIN attachments a ON a.sha256 = ma.sha256
          WHERE ma.message_id = m.id) AS attachments_json,
        (SELECT json_group_array(json_object('emoji', emoji, 'count', n))
           FROM (SELECT emoji, COUNT(*) AS n FROM reactions
                  WHERE message_id = m.id GROUP BY emoji)) AS reactions_json,
        CASE WHEN f.message_id IS NULL THEN NULL ELSE json_object(
            'origin_message_id', lower(hex(f.origin_message_id)),
            'origin_channel_id', lower(hex(f.origin_channel_id)),
            'origin_author_id', lower(hex(f.origin_author_id)),
            'origin_created_at', f.origin_created_at,
            'origin_content', f.origin_content) END AS forwarded_from_json
     FROM messages m
     LEFT JOIN message_forwards f ON f.message_id = m.id
     WHERE m.channel_id = ?1 AND m.deleted_at IS NULL
     ORDER BY m.seq";

const MESSAGES_COUNT: &str = concat!(
    "SELECT COUNT(*) FROM messages m JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " WHERE m.deleted_at IS NULL AND ",
    community_channel!(),
    " AND ?1 IS NOT NULL"
);

const PINS: &str = concat!(
    "SELECT p.channel_id, p.message_id, p.pinned_by, p.pinned_at
     FROM pinned_messages p
     JOIN messages m ON m.id = p.message_id AND m.deleted_at IS NULL
     JOIN channels c ON c.id = p.channel_id ",
    parent_joins!(),
    " WHERE ",
    community_channel!(),
    " AND ?1 IS NOT NULL ORDER BY p.channel_id, p.pinned_at"
);

const EMOJI: &str = "SELECT id, name, lower(hex(sha256)) AS sha256, uploader_id, created_at
     FROM custom_emoji WHERE ?1 IS NOT NULL ORDER BY id";

const ATTACHMENTS: &str = concat!(
    "SELECT lower(hex(a.sha256)) AS sha256, a.size, a.content_type,
        a.filename, a.created_at
     FROM attachments a
     WHERE ?1 IS NOT NULL
       AND (EXISTS (SELECT 1 FROM message_attachments ma
                      JOIN messages m ON m.id = ma.message_id
                      JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " WHERE ma.sha256 = a.sha256 AND m.deleted_at IS NULL AND ",
    community_channel!(),
    ")
            OR EXISTS (SELECT 1 FROM custom_emoji e WHERE e.sha256 = a.sha256))
     ORDER BY a.sha256"
);

const ATTACHMENTS_COUNT: &str = concat!(
    "SELECT COUNT(*) FROM attachments a
     WHERE ?1 IS NOT NULL
       AND (EXISTS (SELECT 1 FROM message_attachments ma
                      JOIN messages m ON m.id = ma.message_id
                      JOIN channels c ON c.id = m.channel_id ",
    parent_joins!(),
    " WHERE ma.sha256 = a.sha256 AND m.deleted_at IS NULL AND ",
    community_channel!(),
    ")
            OR EXISTS (SELECT 1 FROM custom_emoji e WHERE e.sha256 = a.sha256))"
);

/// Every read takes `?1` so one helper binds them all; the value is unused unless noted.
impl Store {
    pub async fn export_space_settings(&self) -> anyhow::Result<Option<serde_json::Value>> {
        self.one_row(SPACE, Uuid::nil()).await
    }

    pub fn export_space_roles(&self) -> RowStream {
        self.stream_rows(ROLES, Uuid::nil())
    }

    pub fn export_space_categories(&self) -> RowStream {
        self.stream_rows(CATEGORIES, Uuid::nil())
    }

    pub fn export_space_channels(&self) -> RowStream {
        self.stream_rows(CHANNELS, Uuid::nil())
    }

    pub fn export_space_members(&self) -> RowStream {
        self.stream_rows(MEMBERS, Uuid::nil())
    }

    pub fn export_space_messages(&self, channel: Uuid) -> RowStream {
        self.stream_rows(MESSAGES, channel)
    }

    pub fn export_space_pins(&self) -> RowStream {
        self.stream_rows(PINS, Uuid::nil())
    }

    pub fn export_space_emoji(&self) -> RowStream {
        self.stream_rows(EMOJI, Uuid::nil())
    }

    pub fn export_space_attachments(&self) -> RowStream {
        self.stream_rows(ATTACHMENTS, Uuid::nil())
    }

    pub async fn export_space_counts(&self) -> anyhow::Result<(i64, i64)> {
        let messages = self.count_rows(MESSAGES_COUNT, Uuid::nil()).await?;
        let files = self.count_rows(ATTACHMENTS_COUNT, Uuid::nil()).await?;
        Ok((messages, files))
    }
}
