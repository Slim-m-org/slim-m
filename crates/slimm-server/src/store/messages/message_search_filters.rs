// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The structured half of a message search: every operator `http::search`
//! resolved to SQL-ready values, and the predicates they add to the query.
//! Each predicate is an ordinary SQL condition on `m` the query text can
//! never reach, and each probes a table by its message key, so none needs
//! an index of its own; see docs/search.md for the grammar.

use sqlx::{QueryBuilder, Sqlite};

use crate::ids::{MessageId, UserId};

/// One `has:` value. Several are ANDed: `has:image has:link` wants both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HasKind {
    /// Any attachment at all.
    Attachment,
    /// An `image/*` attachment, GIFs included.
    Image,
    /// A `video/*` attachment.
    Video,
    /// A voice message.
    Voice,
    /// An attachment that is none of the three above: a document, an archive, an audio file.
    File,
    /// What looks like a URL: a plain, case-sensitive substring match, not a link parse.
    Link,
    /// A rich embed a bot or webhook attached.
    Embed,
    /// A poll.
    Poll,
}

impl HasKind {
    /// Every value, in the order the API documents them.
    pub const ALL: [HasKind; 8] = [
        HasKind::Attachment,
        HasKind::Image,
        HasKind::Video,
        HasKind::Voice,
        HasKind::File,
        HasKind::Link,
        HasKind::Embed,
        HasKind::Poll,
    ];

    /// The value as it is spelled on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            HasKind::Attachment => "attachment",
            HasKind::Image => "image",
            HasKind::Video => "video",
            HasKind::Voice => "voice",
            HasKind::File => "file",
            HasKind::Link => "link",
            HasKind::Embed => "embed",
            HasKind::Poll => "poll",
        }
    }

    pub fn parse(value: &str) -> Option<HasKind> {
        HasKind::ALL.into_iter().find(|kind| kind.as_str() == value)
    }

    /// Each is an `IN` over the table that holds the kind, so the planner can start from the
    /// few messages carrying it rather than test every message in scope one by one.
    fn predicate(self) -> &'static str {
        match self {
            HasKind::Attachment => " AND m.id IN (SELECT message_id FROM message_attachments)",
            HasKind::Image => ATTACHMENT_IMAGE,
            HasKind::Video => ATTACHMENT_VIDEO,
            HasKind::Voice => {
                " AND m.id IN (SELECT message_id FROM message_attachments \
                 WHERE voice_duration_ms IS NOT NULL)"
            }
            HasKind::File => ATTACHMENT_FILE,
            HasKind::Link => " AND (m.content LIKE '%http://%' OR m.content LIKE '%https://%')",
            HasKind::Embed => " AND m.id IN (SELECT message_id FROM message_embeds)",
            HasKind::Poll => " AND m.id IN (SELECT message_id FROM polls)",
        }
    }
}

const ATTACHMENT_IMAGE: &str = " AND m.id IN (SELECT ma.message_id FROM message_attachments ma \
     JOIN attachments a ON a.sha256 = ma.sha256 \
     WHERE ma.voice_duration_ms IS NULL AND a.content_type LIKE 'image/%')";

const ATTACHMENT_VIDEO: &str = " AND m.id IN (SELECT ma.message_id FROM message_attachments ma \
     JOIN attachments a ON a.sha256 = ma.sha256 \
     WHERE ma.voice_duration_ms IS NULL AND a.content_type LIKE 'video/%')";

const ATTACHMENT_FILE: &str = " AND m.id IN (SELECT ma.message_id FROM message_attachments ma \
     JOIN attachments a ON a.sha256 = ma.sha256 \
     WHERE ma.voice_duration_ms IS NULL \
     AND a.content_type NOT LIKE 'image/%' AND a.content_type NOT LIKE 'video/%')";

/// The operators of an advanced search, already resolved to what SQL needs.
/// The channel scope is not here: [`crate::store::Store::search_messages`]
/// takes it as its own parameter, answered once before this is built.
#[derive(Debug, Default)]
pub struct MessageSearchFilters {
    /// `from:`, compared case-insensitively; live usernames are unique that way since migration 0095.
    pub author_username: Option<String>,
    pub has: Vec<HasKind>,
    /// `mentions:`, resolved to a live account: a direct `@username` outside code that
    /// pinged them (`message_mentions.direct`), never an `@everyone`, `@here`, role or reply ping.
    pub mentions: Option<UserId>,
    /// `pinned:true` keeps only pinned messages, `pinned:false` only unpinned ones.
    pub pinned: Option<bool>,
    /// Inclusive: `created_at >= after_ms`.
    pub after_ms: Option<i64>,
    /// Exclusive: `created_at < before_ms`, so a day named by `before:` is excluded whole.
    pub before_ms: Option<i64>,
    /// The page cursor across channels: only messages after this one in `(created_at, seq, id)`
    /// result order, since per-channel seqs say nothing about each other.
    pub before_id: Option<MessageId>,
}

impl MessageSearchFilters {
    /// Appends every operator's predicate to `builder`, each starting with ` AND `.
    pub fn push_predicates(&self, builder: &mut QueryBuilder<Sqlite>) {
        if let Some(username) = &self.author_username {
            builder.push(" AND m.author_id = (SELECT id FROM users WHERE lower(username) = lower(");
            builder.push_bind(username.to_owned());
            builder.push(") AND deleted_at IS NULL)");
        }
        for kind in &self.has {
            builder.push(kind.predicate());
        }
        if let Some(mentioned) = self.mentions {
            builder.push(" AND m.id IN (SELECT message_id FROM message_mentions WHERE user_id = ");
            builder.push_bind(mentioned);
            builder.push(" AND direct = 1)");
        }
        match self.pinned {
            Some(true) => {
                builder.push(" AND m.id IN (SELECT message_id FROM pinned_messages)");
            }
            Some(false) => {
                builder.push(
                    " AND NOT EXISTS (SELECT 1 FROM pinned_messages pm WHERE pm.message_id = m.id)",
                );
            }
            None => {}
        }
        if let Some(after_ms) = self.after_ms {
            builder.push(" AND m.created_at >= ");
            builder.push_bind(after_ms);
        }
        if let Some(before_ms) = self.before_ms {
            builder.push(" AND m.created_at < ");
            builder.push_bind(before_ms);
        }
        if let Some(before_id) = self.before_id {
            builder.push(
                " AND (m.created_at, m.seq, m.id) < (SELECT created_at, seq, id FROM messages WHERE id = ",
            );
            builder.push_bind(before_id);
            builder.push(")");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::HasKind;

    #[test]
    fn every_kind_round_trips_through_its_wire_spelling() {
        for kind in HasKind::ALL {
            assert_eq!(HasKind::parse(kind.as_str()), Some(kind));
        }
        assert_eq!(HasKind::parse("gif"), None);
        assert_eq!(HasKind::parse("Image"), None);
    }
}
