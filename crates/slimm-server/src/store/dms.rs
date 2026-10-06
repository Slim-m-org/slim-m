// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Direct messages: a DM is a channel of kind [`DM_CHANNEL_KIND`] with one or
//! two participants recorded in `dm_channels`, normalized so the pair (a, b)
//! and (b, a) always resolve to the same row and hence the same channel.
//!
//! A pair may name the same user twice: [`Store::open_dm`] no longer refuses
//! `caller == target`, and that self pair is a personal space rather than a
//! conversation with anyone else - notes that sync across devices the same
//! way any other channel does, with nobody else ever able to reach it.
//!
//! Modelling a DM as a channel is what lets every other feature - sending,
//! editing, keyset pagination, full-text search, bundled sync, push fan-out,
//! the WebSocket fan-out filter, and voice tokens and rosters - keep working
//! completely unchanged: all of them already gate on [`Store::has_permission`]
//! / [`Store::permissions_in_channel`], and [`Store::permissions_in_channel`]
//! is the one place taught about the `dm` kind (see [`dm_permissions`]).
//!
//! What is deliberately NOT reused is the role/overwrite evaluator itself.
//! Membership of the pair is the only thing that grants access to a DM, and
//! that has to hold even against `ADMINISTRATOR`, which the ordinary
//! evaluator bypasses everywhere else on purpose. Folding DM access into that
//! evaluator (say, as a synthesized per-member overwrite) would put it one
//! `ADMINISTRATOR` check away from an administrator reading every DM on the
//! deployment; a separate explicit check has no such bypass to accidentally
//! inherit.

use std::collections::HashMap;

use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

use super::{Channel, Store, User, now_ms};

pub(crate) const DM_CHANNEL_KIND: &str = "dm";

/// Everything a DM participant can ever do inside it. Deliberately narrower
/// than [`Permissions::ALL`]: there is no moderation and no roles, only a
/// conversation between two people - voice and the canvas are the two
/// exceptions, since a call or a shared working surface between exactly those
/// two people is still just that conversation. `USE_CANVAS` here reverses an
/// earlier owner call (backlog, 2026-08-13, "there also should not be a
/// canvas in text channels, only voice channels") that had also read as
/// excluding DMs; the owner has since asked for one directly, to work through
/// something 1-on-1 without a voice channel. `MANAGE_CANVAS` stays out like
/// every other moderation bit, so a DM canvas has no "clear" or rearrange-
/// anyone's-object power, only placing and removing your own. `KICK_MEMBERS`
/// stays out on purpose too, so neither party can evict the other from their
/// own call; leaving is each side's own doing.
pub(super) const DM_BASE: Permissions = Permissions::VIEW_CHANNEL
    .union(Permissions::SEND_MESSAGES)
    .union(Permissions::ADD_REACTIONS)
    .union(Permissions::ATTACH_FILES)
    .union(Permissions::CONNECT)
    .union(Permissions::SPEAK)
    .union(Permissions::USE_CANVAS);

/// What a block removes: everything that creates new content, voice and the
/// canvas included, since a blocked person must not be able to ring, join a
/// call, or draw on the shared canvas any more than they can send a message.
/// `VIEW_CHANNEL` survives so a block stops a conversation without erasing
/// it; a party who blocked (or was blocked by) the other can still read what
/// already happened, and it also means an out-of-band delete of `user_blocks`
/// cannot double as a way to silently reopen a hidden history.
///
/// **Message history and the canvas are NOT symmetric here, deliberately.**
/// Reading messages needs `VIEW_CHANNEL` alone (`http/messages.rs`), so a
/// block leaves history readable. Every canvas route, the viewport read
/// included (`http/canvas.rs`), needs `USE_CANVAS` as well - and that bit is
/// defined as "view and draw" in one piece (`permissions.rs`), so removing
/// it necessarily removes viewing too. A blocked party therefore gets
/// `Forbidden` on the canvas rather than a frozen last state.
///
/// That asymmetry is a consequence of the permission model, not a decision
/// taken about blocking. Splitting `USE_CANVAS` into separate view and draw
/// bits would let a block hide the drawing without hiding the work, and is
/// worth considering - but it changes the meaning of the bit for every
/// channel, not just a DM, so it is left as an open question rather than
/// done as a side effect. `dm_canvas.rs` pins the current behaviour so it
/// cannot drift silently either way.
pub(super) const BLOCKED_DENY: Permissions = Permissions::SEND_MESSAGES
    .union(Permissions::ADD_REACTIONS)
    .union(Permissions::ATTACH_FILES)
    .union(Permissions::CONNECT)
    .union(Permissions::SPEAK)
    .union(Permissions::USE_CANVAS);

/// Why opening a DM failed.
#[derive(Debug)]
pub enum OpenDmError {
    /// The target account does not exist, or has been deleted.
    UserNotFound,
    /// Either party has blocked the other.
    Blocked,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for OpenDmError {
    fn from(err: sqlx::Error) -> Self {
        OpenDmError::Internal(err.into())
    }
}

impl From<anyhow::Error> for OpenDmError {
    fn from(err: anyhow::Error) -> Self {
        OpenDmError::Internal(err)
    }
}

/// One of the caller's DM conversations: the channel, the other participant's
/// public profile, and the caller's own unread count in it - exactly what the
/// client's Direct Messages rail renders.
#[derive(Debug, Clone)]
pub struct DmConversation {
    pub channel_id: ChannelId,
    pub other: User,
    pub unread: i64,
    pub created_at: i64,
}

/// Orders a pair so (a, b) and (b, a) always produce the same result. `Uuid`
/// orders by its raw bytes, the same order SQLite compares a `BLOB` column
/// with, so this matches the `CHECK (user_a <= user_b)` constraint the
/// migration puts on the table. A self pair (a == b) is already ordered
/// either way this branches, which is exactly what admits it.
fn normalize_pair(a: UserId, b: UserId) -> (UserId, UserId) {
    if a.0 < b.0 { (a, b) } else { (b, a) }
}

impl Store {
    /// Opens the DM channel between two users, creating it on first contact.
    /// `caller == target` opens (or returns) the caller's own personal space
    /// rather than being refused: see the module doc comment.
    ///
    /// Idempotent and race-safe: two callers opening the same pair at once
    /// converge on one channel, never two. This reads whether the pair
    /// already has a channel before deciding whether to create one, so it
    /// uses [`Store::begin_write`] (`BEGIN IMMEDIATE`) rather than a plain
    /// transaction: a deferred transaction that has already taken a read
    /// snapshot cannot promote itself to a writer if another connection
    /// takes the write lock first, and SQLite reports that as SQLITE_BUSY
    /// immediately rather than waiting. Taking the write lock up front
    /// instead makes a second concurrent open queue behind the first (up to
    /// the pool's `busy_timeout`) and then find the row the first one just
    /// committed, rather than racing it to insert a second one.
    ///
    /// Blocking is checked before the pair table is even touched, so a blocked
    /// relationship never learns whether a channel already exists between
    /// them, and a re-open is refused exactly as the first open would be.
    pub async fn open_dm(&self, caller: UserId, target: UserId) -> Result<Channel, OpenDmError> {
        if self.user_profile(target).await?.is_none() {
            return Err(OpenDmError::UserNotFound);
        }
        // A self pair can never be blocked (refused at the HTTP layer), so skip it.
        if caller != target
            && (self.has_blocked(caller, target).await? || self.has_blocked(target, caller).await?)
        {
            return Err(OpenDmError::Blocked);
        }

        let (user_a, user_b) = normalize_pair(caller, target);
        let mut tx = self.begin_write().await?;

        if let Some(channel_id) = sqlx::query_scalar!(
            r#"SELECT channel_id AS "channel_id!: ChannelId"
               FROM dm_channels WHERE user_a = ? AND user_b = ?"#,
            user_a,
            user_b
        )
        .fetch_optional(&mut *tx)
        .await?
        {
            // Opening un-hides it for the caller; see `dm_hides` (0057_dm_hides.sql).
            sqlx::query!(
                "DELETE FROM dm_hides WHERE user_id = ? AND channel_id = ?",
                caller,
                channel_id
            )
            .execute(&mut *tx)
            .await?;
            tx.commit().await?;
            return self.channel(channel_id).await?.ok_or_else(|| {
                anyhow::anyhow!("dm_channels row exists but its channel does not").into()
            });
        }

        let channel_id = ChannelId::generate();
        let now = now_ms();
        // A DM has no name of its own; the client renders the other
        // participant's display name instead, carried on `DmConversation`.
        sqlx::query!(
            "INSERT INTO channels (id, name, kind, created_at) VALUES (?, '', 'dm', ?)",
            channel_id,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
             VALUES (?, 'message', 1), (?, 'canvas', 1)",
            channel_id,
            channel_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO dm_channels (channel_id, user_a, user_b, created_at)
             VALUES (?, ?, ?, ?)",
            channel_id,
            user_a,
            user_b,
            now
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        Ok(Channel {
            id: channel_id,
            name: String::new(),
            kind: DM_CHANNEL_KIND.to_owned(),
            topic: None,
            // Never read: a DM is excluded from every position-ordered query.
            position: 0,
            parent_message_id: None,
            // Never read: a DM is excluded from every category grouping.
            category_id: None,
            created_at: now,
            // Never read: a DM has no slow-mode setter of its own.
            slow_mode_seconds: 0,
            join_muted: false,
        })
    }

    /// Every DM channel `user_id` is a party to, hidden ones included.
    ///
    /// Deliberately NOT [`Self::list_dm_conversations`], which filters out
    /// conversations the caller has hidden from their own sidebar. That
    /// filter is a display preference and must never decide a safety act:
    /// `http::members::evict_from_voice` used the filtered list, so a member
    /// who hid a DM while staying connected to its call kept live audio
    /// after being timed out or removed. Hiding is one ordinary request away,
    /// which made moderation defeatable by anyone who saw it coming.
    pub(crate) async fn dm_channel_ids_for_user(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Vec<ChannelId>> {
        let rows = sqlx::query!(
            r#"SELECT channel_id AS "channel_id!: ChannelId"
               FROM dm_channels
               WHERE user_a = ? OR user_b = ?"#,
            user_id,
            user_id,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|row| row.channel_id).collect())
    }

    /// The caller's DM conversations, most recently active first. A
    /// conversation whose other participant has been deleted is omitted
    /// rather than shown with nothing to render for them, and so is one the
    /// caller has hidden (`dm_hides`, 0057_dm_hides.sql) - unless it has
    /// picked up new activity since, which is what brings a closed DM back
    /// on its own rather than silently dropping whatever the other person
    /// sends next.
    ///
    /// Activity is the newest live message's `created_at`, found by seeking
    /// `ORDER BY seq DESC LIMIT 1` rather than `MAX(created_at)`: both are
    /// allocated in the same transaction so the answers are identical, but
    /// only the seq form can use `messages_channel_live` as a single-row
    /// seek - the MAX form scanned every live message in the channel, per
    /// conversation, on a table nothing ever sweeps (measured at ~7,700x
    /// slower by the 2026-08-11 review at 200k rows). `tests/dm_activity.rs`
    /// pins both the plan and the equivalence. The hide filter is applied in
    /// an outer query rather than folded into the same `WHERE` as the pair
    /// match, because SQLite cannot see a `SELECT`-list alias (`activity_at`)
    /// from its own `WHERE` clause.
    pub async fn list_dm_conversations(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Vec<DmConversation>> {
        let rows = sqlx::query!(
            r#"SELECT channel_id AS "channel_id!: ChannelId",
                      other_id AS "other_id!: UserId",
                      created_at AS "created_at!",
                      activity_at AS "activity_at!: i64"
               FROM (
                   SELECT d.channel_id AS channel_id,
                          CASE WHEN d.user_a = ? THEN d.user_b ELSE d.user_a END AS other_id,
                          c.created_at AS created_at,
                          COALESCE(
                              (SELECT m.created_at FROM messages m
                               WHERE m.channel_id = d.channel_id AND m.deleted_at IS NULL
                               ORDER BY m.seq DESC LIMIT 1),
                              c.created_at
                          ) AS activity_at,
                          h.hidden_at AS hidden_at
                   FROM dm_channels d
                   JOIN channels c ON c.id = d.channel_id AND c.deleted_at IS NULL
                   LEFT JOIN dm_hides h ON h.channel_id = d.channel_id AND h.user_id = ?
                   WHERE d.user_a = ? OR d.user_b = ?
               )
               WHERE hidden_at IS NULL OR hidden_at < activity_at
               ORDER BY "activity_at!: i64" DESC"#,
            user_id,
            user_id,
            user_id,
            user_id
        )
        .fetch_all(&self.pool)
        .await?;

        // One profile fetch and one unread count for the whole list, not a pair per conversation; see SRV3.
        let other_ids: Vec<UserId> = rows.iter().map(|row| row.other_id).collect();
        let channel_ids: Vec<ChannelId> = rows.iter().map(|row| row.channel_id).collect();
        let profiles: HashMap<UserId, User> = self
            .user_profiles(&other_ids)
            .await?
            .into_iter()
            .map(|user| (user.id, user))
            .collect();
        let unread = self.unread_counts(user_id, &channel_ids).await?;

        let mut conversations = Vec::with_capacity(rows.len());
        for row in rows {
            // A missing profile is a since-deleted other account, skipped as the per-row None was.
            let Some(other) = profiles.get(&row.other_id).cloned() else {
                continue;
            };
            conversations.push(DmConversation {
                channel_id: row.channel_id,
                other,
                // Absent from the map means nothing unread; see unread_counts.
                unread: unread.get(&row.channel_id).copied().unwrap_or(0),
                created_at: row.created_at,
            });
        }
        Ok(conversations)
    }

    /// The two accounts a DM channel is between, or `None` if it is not a DM.
    ///
    /// Exists so a caller with many candidates can narrow them to the pair
    /// before asking anything per candidate; see [`Store::viewers_among`].
    pub(crate) async fn dm_pair(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Option<(UserId, UserId)>> {
        let pair = sqlx::query!(
            r#"SELECT user_a AS "user_a!: UserId", user_b AS "user_b!: UserId"
               FROM dm_channels WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(pair.map(|p| (p.user_a, p.user_b)))
    }

    /// The DM channel between two specific accounts, if the pair has ever
    /// opened one. Read-only, unlike [`Store::open_dm`]: a caller checking
    /// whether there is a call to act on must not create a channel just by
    /// asking, so this answers `None` rather than opening one.
    pub(crate) async fn dm_channel_for_pair(
        &self,
        a: UserId,
        b: UserId,
    ) -> anyhow::Result<Option<ChannelId>> {
        let (user_a, user_b) = normalize_pair(a, b);
        let channel_id = sqlx::query_scalar!(
            r#"SELECT channel_id AS "channel_id!: ChannelId"
               FROM dm_channels WHERE user_a = ? AND user_b = ?"#,
            user_a,
            user_b
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(channel_id)
    }

    /// Closes a DM out of `user_id`'s own sidebar - a per-viewer hide, never
    /// a delete: no message is touched, and the other participant's own list
    /// is unaffected. Idempotent, and silently a no-op if the pair has never
    /// opened a channel, the same way [`Store::open_dm`]'s eventual read side
    /// treats "no channel yet" and "hidden" as the same absence.
    ///
    /// Independent of both mute (`channel_notification_prefs`) and blocking
    /// (`user_blocks`): hiding is about the caller's own clutter, not about
    /// notifications or safety, and neither of those tables is read or
    /// written here.
    ///
    /// The write is a plain upsert rather than "insert if absent": hiding an
    /// already-hidden conversation moves `hidden_at` forward, which matters
    /// because `list_dm_conversations` treats a *stale* hide (one older than
    /// the conversation's latest activity) as no longer in effect - closing
    /// it again after new activity has to re-arm that comparison.
    pub async fn hide_dm_conversation(&self, user_id: UserId, other: UserId) -> anyhow::Result<()> {
        let Some(channel_id) = self.dm_channel_for_pair(user_id, other).await? else {
            return Ok(());
        };
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO dm_hides (user_id, channel_id, hidden_at) VALUES (?, ?, ?)
             ON CONFLICT (user_id, channel_id) DO UPDATE SET hidden_at = excluded.hidden_at",
            user_id,
            channel_id,
            now
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// The explicit DM authorization check that [`Store::permissions_in_channel`]
    /// delegates to for a `dm`-kind channel, instead of running the ordinary
    /// role/overwrite evaluator. A caller outside the pair gets
    /// [`Permissions::NONE`] regardless of any role they hold -
    /// `ADMINISTRATOR` included, since that bypass belongs to the
    /// deployment's own channels, not to a conversation between two
    /// specific people who happen to be on it.
    pub(crate) async fn dm_permissions(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<Permissions> {
        let pair = sqlx::query!(
            r#"SELECT user_a AS "user_a!: UserId", user_b AS "user_b!: UserId"
               FROM dm_channels WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?;
        let Some(pair) = pair else {
            return Ok(Permissions::NONE);
        };

        let other = if user_id == pair.user_a {
            pair.user_b
        } else if user_id == pair.user_b {
            pair.user_a
        } else {
            return Ok(Permissions::NONE);
        };

        // A personal space's "other" party is the caller themself; see open_dm.
        if other != user_id
            && (self.has_blocked(user_id, other).await? || self.has_blocked(other, user_id).await?)
        {
            return Ok(DM_BASE.remove(BLOCKED_DENY));
        }
        Ok(DM_BASE)
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_pair;
    use crate::ids::UserId;
    use uuid::Uuid;

    /// The canonical pair is the same whichever order the two ids arrive in,
    /// which is what makes a DM between two people resolve to one channel
    /// rather than a second one when the other person writes first.
    #[test]
    fn normalize_pair_is_symmetric_and_ordered() {
        let lo = UserId(Uuid::from_u128(1));
        let hi = UserId(Uuid::from_u128(2));
        assert_eq!(normalize_pair(lo, hi), normalize_pair(hi, lo));
        assert_eq!(normalize_pair(hi, lo), (lo, hi));
    }
}
