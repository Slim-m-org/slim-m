// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who has a board open right now, kept per connection in memory like
//! [`super::viewing::ViewingTracker`].
//!
//! Declarations only mark a (user, channel) pair dirty; [`CanvasViewers::flush`] turns the dirty
//! pairs into the few changes worth publishing, so a toggle storm costs one frame per pair per
//! flush and nothing when it ends where it began.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};

use super::Visibility;
use crate::ids::{ChannelId, UserId};
use crate::store::now_ms;

/// A user's live connections on one board, each with when it opened it (ms since epoch).
pub type Entry = BTreeMap<u64, i64>;

/// A change of whether one user is shown as viewing one board.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ViewerChange {
    pub channel_id: ChannelId,
    pub user_id: UserId,
    pub viewing: bool,
}

/// The one rule for whether a viewer is shown: a live connection on the board and a chosen
/// visibility that is not Hidden. An unknown visibility fails closed.
pub fn viewer_shown(entry: &Entry, visibility: Option<Visibility>) -> bool {
    !entry.is_empty() && matches!(visibility, Some(v) if v != Visibility::Hidden)
}

struct Connection {
    user_id: UserId,
    channels: HashSet<ChannelId>,
}

#[derive(Default)]
struct Inner {
    boards: HashMap<ChannelId, HashMap<UserId, Entry>>,
    connections: HashMap<u64, Connection>,
    /// When each published pair first became shown; time spent hidden never counts.
    published: HashMap<(UserId, ChannelId), i64>,
    /// The last visibility change of a pair that is not published yet; `since` never predates it.
    floor: HashMap<(UserId, ChannelId), i64>,
    dirty: HashSet<(UserId, ChannelId)>,
}

#[derive(Clone, Default)]
pub struct CanvasViewers {
    inner: Arc<Mutex<Inner>>,
}

impl CanvasViewers {
    /// The boards `connection` currently counts as viewing.
    pub fn channels_of(&self, connection: u64) -> HashSet<ChannelId> {
        lock(&self.inner)
            .connections
            .get(&connection)
            .map(|c| c.channels.clone())
            .unwrap_or_default()
    }

    /// Replaces the boards a connection is viewing, marking every pair that moved dirty.
    pub fn replace(
        &self,
        user_id: UserId,
        connection: u64,
        channels: HashSet<ChannelId>,
        now_ms: i64,
    ) {
        let mut inner = lock(&self.inner);
        let previous = inner
            .connections
            .get(&connection)
            .map(|c| c.channels.clone())
            .unwrap_or_default();
        for channel_id in previous.difference(&channels) {
            inner.detach(user_id, connection, *channel_id);
        }
        for channel_id in channels.difference(&previous) {
            inner
                .boards
                .entry(*channel_id)
                .or_default()
                .entry(user_id)
                .or_default()
                .insert(connection, now_ms);
            inner.dirty.insert((user_id, *channel_id));
        }
        if channels.is_empty() {
            inner.connections.remove(&connection);
        } else {
            inner
                .connections
                .insert(connection, Connection { user_id, channels });
        }
    }

    /// Clears everything a connection reported, on every exit path of its socket.
    pub fn remove_connection(&self, connection: u64) {
        let mut inner = lock(&self.inner);
        let Some(gone) = inner.connections.remove(&connection) else {
            return;
        };
        for channel_id in gone.channels {
            inner.detach(gone.user_id, connection, channel_id);
        }
    }

    /// Marks every pair a user is viewing dirty, for a visibility change at `now_ms`.
    pub fn mark_user_dirty(&self, user_id: UserId, now_ms: i64) {
        let mut inner = lock(&self.inner);
        let pairs: Vec<_> = inner
            .connections
            .values()
            .filter(|c| c.user_id == user_id)
            .flat_map(|c| c.channels.iter().map(|ch| (user_id, *ch)))
            .collect();
        for pair in &pairs {
            if !inner.published.contains_key(pair) {
                inner.floor.insert(*pair, now_ms);
            }
        }
        inner.dirty.extend(pairs);
    }

    /// Drops a board's entries and forgets what was published for it, without a frame: clients
    /// drop the roster themselves when the channel update says the board is closed.
    pub fn close_channel(&self, channel_id: ChannelId) {
        let mut inner = lock(&self.inner);
        inner.boards.remove(&channel_id);
        inner.published.retain(|(_, ch), _| *ch != channel_id);
        inner.floor.retain(|(_, ch), _| *ch != channel_id);
        inner.dirty.retain(|(_, ch)| *ch != channel_id);
        for connection in inner.connections.values_mut() {
            connection.channels.remove(&channel_id);
        }
    }

    /// The changes since the last flush, one per dirty pair whose shown state moved.
    pub fn flush(&self, visibility: impl Fn(UserId) -> Option<Visibility>) -> Vec<ViewerChange> {
        self.flush_at(visibility, now_ms())
    }

    /// [`CanvasViewers::flush`] with an explicit clock, for a pair whose arrival is unknown.
    pub fn flush_at(
        &self,
        visibility: impl Fn(UserId) -> Option<Visibility>,
        now_ms: i64,
    ) -> Vec<ViewerChange> {
        let mut inner = lock(&self.inner);
        let dirty = std::mem::take(&mut inner.dirty);
        let mut changes = Vec::new();
        for (user_id, channel_id) in dirty {
            let entry = inner
                .boards
                .get(&channel_id)
                .and_then(|users| users.get(&user_id));
            let shown = entry.is_some_and(|entry| viewer_shown(entry, visibility(user_id)));
            let arrived = entry.and_then(|entry| entry.values().min().copied());
            let was = inner.published.contains_key(&(user_id, channel_id));
            if shown == was {
                continue;
            }
            if arrived.is_none() {
                inner.floor.remove(&(user_id, channel_id));
            }
            if shown {
                let floor = inner.floor.remove(&(user_id, channel_id));
                let since = arrived.unwrap_or(now_ms).max(floor.unwrap_or(i64::MIN));
                inner.published.insert((user_id, channel_id), since);
            } else {
                inner.published.remove(&(user_id, channel_id));
            }
            changes.push(ViewerChange {
                channel_id,
                user_id,
                viewing: shown,
            });
        }
        changes
    }

    /// Every user with a live connection on `channel_id`, with their entry; the caller applies [`viewer_shown`].
    pub fn entries(&self, channel_id: ChannelId) -> Vec<(UserId, Entry)> {
        lock(&self.inner)
            .boards
            .get(&channel_id)
            .map(|users| users.iter().map(|(u, e)| (*u, e.clone())).collect())
            .unwrap_or_default()
    }

    /// When `user_id` started being shown on `channel_id`: the published time, or for a pair not
    /// published yet its earliest open, never earlier than their last visibility change.
    pub fn shown_since(&self, user_id: UserId, channel_id: ChannelId) -> Option<i64> {
        let inner = lock(&self.inner);
        let pair = (user_id, channel_id);
        if let Some(since) = inner.published.get(&pair) {
            return Some(*since);
        }
        let arrived = inner
            .boards
            .get(&channel_id)?
            .get(&user_id)?
            .values()
            .min()?;
        Some(*arrived.max(inner.floor.get(&pair).unwrap_or(&i64::MIN)))
    }

    /// Boards that have any live connection.
    pub fn open_channels(&self) -> HashSet<ChannelId> {
        lock(&self.inner).boards.keys().copied().collect()
    }
}

impl Inner {
    fn detach(&mut self, user_id: UserId, connection: u64, channel_id: ChannelId) {
        if let Some(users) = self.boards.get_mut(&channel_id) {
            if let Some(entry) = users.get_mut(&user_id) {
                entry.remove(&connection);
                if entry.is_empty() {
                    users.remove(&user_id);
                }
            }
            if users.is_empty() {
                self.boards.remove(&channel_id);
            }
        }
        self.dirty.insert((user_id, channel_id));
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(test)]
mod tests;
