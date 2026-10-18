// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resolving a list of arbitrary channel ids to the channels a permission
//! check evaluates against, and answering the DM branch for all of them at
//! once, with a query count that does not grow with the list.
//!
//! [`Store::permissions_in_channels`] is the only caller, and it is asked
//! about however many channels share an attachment: `may_link` hands it every
//! channel that has ever attached one sha256, so a widely forwarded image
//! turned one message send into a round trip per channel. Splitting the
//! resolution out here keeps `permissions_batch.rs` inside its line budget and
//! puts the batched shapes next to each other, where a later reader can see
//! that all three rounds are bounded.

use std::collections::{HashMap, HashSet};

use sqlx::{QueryBuilder, Row};

use super::super::dms::{BLOCKED_DENY, DM_BASE, DM_CHANNEL_KIND};
use super::super::{Channel, Store};
use crate::ids::{ChannelId, MessageId, UserId};
use crate::notifications::NotificationPreference;
use crate::permissions::Permissions;

/// Where each requested id landed, keyed by the id as it was asked about so a
/// caller can answer for exactly what it was given.
///
/// The three arms are the three shapes a permission answer takes, and they are
/// separated here rather than answered inline because each needs a different
/// batch: `ordinary` carries the channel whose overwrites decide it, `dms`
/// carries the DM channel to look a pair up in, and `dead` needs no query at
/// all.
pub(in crate::store) struct ResolvedChannels {
    pub ordinary: Vec<(ChannelId, Channel)>,
    pub dms: Vec<(ChannelId, ChannelId)>,
    pub dead: Vec<ChannelId>,
}

impl ResolvedChannels {
    /// Files one resolved channel under the id that was asked about, by kind.
    ///
    /// Deliberately blind to `parent_message_id`: a parent channel that is
    /// itself a thread is taken as it stands, which is what
    /// [`Store::permission_channel`] does with its one hop, and re-resolving
    /// here would answer differently from the per-channel path.
    fn place(&mut self, requested: ChannelId, channel: Channel) {
        if channel.kind == DM_CHANNEL_KIND {
            self.dms.push((requested, channel.id));
        } else {
            self.ordinary.push((requested, channel));
        }
    }
}

/// Sorted and deduplicated, so a repeated id costs nothing and the bind lists
/// below stay as short as the distinct set.
fn distinct<T: Copy + Ord>(ids: impl IntoIterator<Item = T>) -> Vec<T> {
    let mut ids: Vec<T> = ids.into_iter().collect();
    ids.sort();
    ids.dedup();
    ids
}

impl Store {
    /// Resolves `channel_ids` to what a permission check should evaluate, in
    /// at most three queries whatever the length of the list.
    ///
    /// Round one fetches the live channels, round two the parent messages of
    /// any threads among them, round three those parents' channels. Three is
    /// the bound rather than a recursion because a thread hop is a single hop;
    /// see [`ResolvedChannels::place`].
    pub(in crate::store) async fn resolve_permission_channels(
        &self,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<ResolvedChannels> {
        let mut out = ResolvedChannels {
            ordinary: Vec::new(),
            dms: Vec::new(),
            dead: Vec::new(),
        };
        let requested = distinct(channel_ids.iter().copied());
        let found = self.channels_by_ids(&requested).await?;

        let mut threads: Vec<(ChannelId, MessageId)> = Vec::new();
        for id in requested {
            match found.get(&id) {
                None => out.dead.push(id),
                Some(channel) => match channel.parent_message_id {
                    Some(parent) => threads.push((id, parent)),
                    None => out.place(id, channel.clone()),
                },
            }
        }
        if threads.is_empty() {
            return Ok(out);
        }

        let parent_ids = distinct(threads.iter().map(|(_, parent)| *parent));
        let parent_channel_ids = self.channels_of_messages(&parent_ids).await?;
        let wanted = distinct(
            parent_channel_ids
                .values()
                .copied()
                .filter(|id| !found.contains_key(id)),
        );
        let parents = self.channels_by_ids(&wanted).await?;

        for (requested, parent_message) in threads {
            let channel = parent_channel_ids
                .get(&parent_message)
                .and_then(|id| parents.get(id).or_else(|| found.get(id)));
            match channel {
                Some(channel) => out.place(requested, channel.clone()),
                None => out.dead.push(requested),
            }
        }
        Ok(out)
    }

    /// The live channels among `ids`, keyed by id. An id that never existed or
    /// has been deleted is simply absent, the same contract
    /// [`Store::user_profiles`] has.
    async fn channels_by_ids(
        &self,
        ids: &[ChannelId],
    ) -> anyhow::Result<HashMap<ChannelId, Channel>> {
        let mut found = HashMap::with_capacity(ids.len());
        // Chunked under SQLite's bind cap; empty makes no chunks.
        for chunk in ids.chunks(super::super::MAX_IDS_PER_QUERY) {
            let mut builder = QueryBuilder::new(
                "SELECT id, name, kind, topic, position, parent_message_id, category_id, \
                 created_at, slow_mode_seconds, join_muted, default_notification, creates_rooms, user_limit, \
                 room_owner_id, room_lobby_id, room_locked \
                 FROM channels WHERE deleted_at IS NULL AND id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                let channel = Channel {
                    id: row.try_get("id")?,
                    name: row.try_get("name")?,
                    kind: row.try_get("kind")?,
                    topic: row.try_get("topic")?,
                    position: row.try_get("position")?,
                    parent_message_id: row.try_get("parent_message_id")?,
                    category_id: row.try_get("category_id")?,
                    created_at: row.try_get("created_at")?,
                    slow_mode_seconds: row.try_get("slow_mode_seconds")?,
                    join_muted: row.try_get("join_muted")?,
                    default_notification: NotificationPreference::parse(
                        &row.try_get::<String, _>("default_notification")?,
                    )
                    .unwrap_or_default(),
                    room: super::super::ChannelRoom {
                        creates_rooms: row.try_get("creates_rooms")?,
                        user_limit: row.try_get("user_limit")?,
                        owner_id: row.try_get("room_owner_id")?,
                        lobby_id: row.try_get("room_lobby_id")?,
                        locked: row.try_get("room_locked")?,
                    },
                };
                found.insert(channel.id, channel);
            }
        }
        Ok(found)
    }

    /// Which channel each of `ids` was posted in.
    ///
    /// Unfiltered by `deleted_at` on purpose: a thread outlives the deletion
    /// of the message it hangs from, and the per-channel path this batches for
    /// reads the row the same way.
    async fn channels_of_messages(
        &self,
        ids: &[MessageId],
    ) -> anyhow::Result<HashMap<MessageId, ChannelId>> {
        let mut found = HashMap::with_capacity(ids.len());
        // Chunked under SQLite's bind cap; empty makes no chunks.
        for chunk in ids.chunks(super::super::MAX_IDS_PER_QUERY) {
            let mut builder =
                QueryBuilder::new("SELECT id, channel_id FROM messages WHERE id IN (");
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                found.insert(row.try_get("id")?, row.try_get("channel_id")?);
            }
        }
        Ok(found)
    }

    /// [`Store::dm_permissions`] for a whole list of DM channels, in a bounded
    /// number of queries rather than one pair lookup and up to two block
    /// lookups per channel.
    ///
    /// Answers identically by construction: the pair rows and the blocks come
    /// from the same tables, and the branches below are the same three the
    /// per-channel version takes - no row or a caller outside the pair grants
    /// nothing, a block in either direction denies, and a personal space's
    /// other party is the caller themself (see `open_dm`).
    pub(in crate::store) async fn dm_permissions_batch(
        &self,
        user_id: UserId,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<HashMap<ChannelId, Permissions>> {
        let mut other_party: HashMap<ChannelId, UserId> = HashMap::new();
        // Chunked under SQLite's bind cap; empty makes no chunks.
        for chunk in channel_ids.chunks(super::super::MAX_IDS_PER_QUERY) {
            let mut builder = QueryBuilder::new(
                "SELECT channel_id, user_a, user_b FROM dm_channels WHERE channel_id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                let channel_id: ChannelId = row.try_get("channel_id")?;
                let user_a: UserId = row.try_get("user_a")?;
                let user_b: UserId = row.try_get("user_b")?;
                let other = if user_id == user_a {
                    user_b
                } else if user_id == user_b {
                    user_a
                } else {
                    continue;
                };
                other_party.insert(channel_id, other);
            }
        }

        let peers = distinct(
            other_party
                .values()
                .copied()
                .filter(|other| *other != user_id),
        );
        let blocked = self.blocked_either_way(user_id, &peers).await?;

        let mut result = HashMap::with_capacity(channel_ids.len());
        for &channel_id in channel_ids {
            let perms = match other_party.get(&channel_id) {
                None => Permissions::NONE,
                Some(other) if *other != user_id && blocked.contains(other) => {
                    DM_BASE.remove(BLOCKED_DENY)
                }
                Some(_) => DM_BASE,
            };
            result.insert(channel_id, perms);
        }
        Ok(result)
    }

    /// Which of `peers` are on either side of a block with `user_id`.
    ///
    /// Two existing reads rather than a third query shape: the deployment-wide
    /// [`Store::blockers_of`] is already the unbounded-on-purpose direction,
    /// and [`Store::blocked_among`] is already the chunked one.
    async fn blocked_either_way(
        &self,
        user_id: UserId,
        peers: &[UserId],
    ) -> anyhow::Result<HashSet<UserId>> {
        if peers.is_empty() {
            return Ok(HashSet::new());
        }
        let mut blocked = self.blocked_among(user_id, peers).await?;
        let asked: HashSet<UserId> = peers.iter().copied().collect();
        for blocker in self.blockers_of(user_id).await? {
            if asked.contains(&blocker) {
                blocked.insert(blocker);
            }
        }
        Ok(blocked)
    }
}
