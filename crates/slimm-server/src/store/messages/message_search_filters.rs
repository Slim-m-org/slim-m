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

    fn predicate(self) -> &'static str {
        match self {
            HasKind::Attachment => {
                " AND EXISTS (SELECT 1 FROM message_attachments ma WHERE ma.message_id = m.id)"
            }
            HasKind::Image => ATTACHMENT_IMAGE,
            HasKind::Video => ATTACHMENT_VIDEO,
            HasKind::Voice => {
                " AND EXISTS (SELECT 1 FROM message_attachments ma \
                 WHERE ma.message_id = m.id AND ma.voice_duration_ms IS NOT NULL)"
            }
            HasKind::File => ATTACHMENT_FILE,
            HasKind::Link => " AND (m.content LIKE '%http://%' OR m.content LIKE '%https://%')",
            HasKind::Embed => {
                " AND EXISTS (SELECT 1 FROM message_embeds me WHERE me.message_id = m.id)"
            }
            HasKind::Poll => " AND EXISTS (SELECT 1 FROM polls p WHERE p.message_id = m.id)",
        }
    }
}

const ATTACHMENT_IMAGE: &str = " AND EXISTS (SELECT 1 FROM message_attachments ma \
     JOIN attachments a ON a.sha256 = ma.sha256 \
     WHERE ma.message_id = m.id AND ma.voice_duration_ms IS NULL \
     AND a.content_type LIKE 'image/%')";

const ATTACHMENT_VIDEO: &str = " AND EXISTS (SELECT 1 FROM message_attachments ma \
     JOIN attachments a ON a.sha256 = ma.sha256 \
     WHERE ma.message_id = m.id AND ma.voice_duration_ms IS NULL \
     AND a.content_type LIKE 'video/%')";

const ATTACHMENT_FILE: &str = " AND EXISTS (SELECT 1 FROM message_attachments ma \
     JOIN attachments a ON a.sha256 = ma.sha256 \
     WHERE ma.message_id = m.id AND ma.voice_duration_ms IS NULL \
     AND a.content_type NOT LIKE 'image/%' AND a.content_type NOT LIKE 'video/%')";

/// The person `mentions:` names, resolved by `http::search` to a live account.
#[derive(Debug, Clone)]
pub struct MentionedUser {
    pub id: UserId,
    pub username: String,
}

/// The operators of an advanced search, already resolved to what SQL needs.
/// The channel scope is not here: [`crate::store::Store::search_messages`]
/// takes it as its own parameter, answered once before this is built.
#[derive(Debug, Default)]
pub struct MessageSearchFilters {
    /// `from:`, compared case-insensitively; live usernames are unique that way since migration 0095.
    pub author_username: Option<String>,
    pub has: Vec<HasKind>,
    /// `mentions:`: a direct `@username` that pinged them, never an `@everyone` or role reach.
    pub mentions: Option<MentionedUser>,
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
    pub(super) fn push_predicates(&self, builder: &mut QueryBuilder<Sqlite>) {
        if let Some(username) = &self.author_username {
            builder.push(" AND m.author_id = (SELECT id FROM users WHERE lower(username) = lower(");
            builder.push_bind(username.to_owned());
            builder.push(") AND deleted_at IS NULL)");
        }
        for kind in &self.has {
            builder.push(kind.predicate());
        }
        if let Some(mentioned) = &self.mentions {
            builder.push(" AND m.id IN (SELECT message_id FROM message_mentions WHERE user_id = ");
            builder.push_bind(mentioned.id);
            builder.push(") AND instr(lower(m.content), ");
            builder.push_bind(format!("@{}", mentioned.username.to_lowercase()));
            builder.push(") > 0");
        }
        if let Some(pinned) = self.pinned {
            builder.push(if pinned {
                " AND EXISTS"
            } else {
                " AND NOT EXISTS"
            });
            builder.push(PINNED_ROW);
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

const PINNED_ROW: &str = " (SELECT 1 FROM pinned_messages pm WHERE pm.message_id = m.id)";

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
