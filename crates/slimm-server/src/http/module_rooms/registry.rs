// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The live rooms, in memory only (decision 0131): one entry per module and
//! channel, holding the state the module last answered and the lock that makes
//! the module the room's only writer.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::{Mutex as TurnLock, MutexGuard};

use super::contract::Next;
use crate::hub::RoomJson;
use crate::ids::{ChannelId, UserId};

/// Rooms one module may hold at once, across every channel.
pub(crate) const MAX_ROOMS_PER_MODULE: usize = 64;
/// Rooms one member may have opened for one module, so one account cannot use up the module's share.
pub(crate) const MAX_ROOMS_PER_OPENER: usize = 4;
/// Inputs that may wait for one room's turn; the next is refused rather than queued.
pub(crate) const MAX_WAITING: usize = 8;

#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub(crate) struct RoomKey {
    pub(crate) module_id: String,
    pub(crate) channel_id: ChannelId,
}

/// What a room holds between inputs.
#[derive(Clone, Debug, Default)]
pub(crate) struct Held {
    pub(crate) seq: u64,
    pub(crate) state: Option<RoomJson>,
    /// The `scene/1` the module drew from [`Self::state`], when it drew one.
    pub(crate) scene: Option<RoomJson>,
    pub(crate) touched_at: i64,
    pub(crate) ended: bool,
}

#[derive(Default)]
pub(crate) struct Room {
    opener: Option<UserId>,
    turn: TurnLock<()>,
    waiting: AtomicUsize,
    held: Mutex<Held>,
}

impl Room {
    pub(crate) async fn take_turn(&self) -> MutexGuard<'_, ()> {
        self.turn.lock().await
    }

    pub(crate) fn held(&self) -> Held {
        self.held
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Stores the module's next state unless the room ended meanwhile; the stored copy on success.
    /// `announce` runs before the room can end, so no state frame follows an `ended` one.
    pub(crate) fn commit(
        &self,
        next: Next,
        now: i64,
        announce: impl FnOnce(&Held),
    ) -> Option<Held> {
        let mut held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        if held.ended {
            return None;
        }
        held.seq += 1;
        held.state = Some(next.state);
        held.scene = next.scene;
        held.touched_at = now;
        announce(&held);
        Some(held.clone())
    }

    /// Marks the room over; the state it held, or `None` when it had none or was already over.
    /// `announce` runs while no commit can slip in after it.
    fn finish(&self, announce: impl FnOnce(&Held)) -> Option<Held> {
        let mut held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        if held.ended {
            return None;
        }
        held.ended = true;
        let had_state = held.state.is_some();
        if had_state {
            announce(&held);
        }
        had_state.then(|| held.clone())
    }
}

/// Why an input could not be given a place in a room.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Refused {
    /// The module already holds [`MAX_ROOMS_PER_MODULE`] rooms.
    TooManyRooms,
    /// The member already opened [`MAX_ROOMS_PER_OPENER`] rooms for this module.
    TooManyOpened,
    /// [`MAX_WAITING`] inputs are already waiting for this room.
    Busy,
}

#[derive(Default)]
pub(crate) struct Rooms {
    live: Mutex<HashMap<RoomKey, Arc<Room>>>,
}

/// An input's place in a room, given back when it is dropped.
pub(crate) struct Entered<'a> {
    rooms: &'a Rooms,
    key: RoomKey,
    pub(crate) room: Arc<Room>,
}

impl Drop for Entered<'_> {
    fn drop(&mut self) {
        self.rooms.leave(&self.key, &self.room);
    }
}

impl Rooms {
    fn live(&self) -> std::sync::MutexGuard<'_, HashMap<RoomKey, Arc<Room>>> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Joins the queue for `key`'s turn, opening the room for `opener` if it has none.
    pub(crate) fn enter(&self, key: &RoomKey, opener: UserId) -> Result<Entered<'_>, Refused> {
        let mut live = self.live();
        let room = match live.get(key) {
            Some(room) => Arc::clone(room),
            None => {
                let held = live.iter().filter(|(k, _)| k.module_id == key.module_id);
                if held.clone().count() >= MAX_ROOMS_PER_MODULE {
                    return Err(Refused::TooManyRooms);
                }
                if held.filter(|(_, r)| r.opener == Some(opener)).count() >= MAX_ROOMS_PER_OPENER {
                    return Err(Refused::TooManyOpened);
                }
                let room = Arc::new(Room {
                    opener: Some(opener),
                    ..Room::default()
                });
                live.insert(key.clone(), Arc::clone(&room));
                room
            }
        };
        if room.waiting.fetch_add(1, Ordering::AcqRel) >= MAX_WAITING {
            room.waiting.fetch_sub(1, Ordering::AcqRel);
            drop(live);
            self.forget_if_unused(key, &room);
            return Err(Refused::Busy);
        }
        Ok(Entered {
            rooms: self,
            key: key.clone(),
            room,
        })
    }

    fn leave(&self, key: &RoomKey, room: &Arc<Room>) {
        room.waiting.fetch_sub(1, Ordering::AcqRel);
        self.forget_if_unused(key, room);
    }

    /// A room nobody waits on and that never got a state is not kept.
    fn forget_if_unused(&self, key: &RoomKey, room: &Arc<Room>) {
        let mut live = self.live();
        let unused = room.waiting.load(Ordering::Acquire) == 0 && room.held().state.is_none();
        if unused && live.get(key).is_some_and(|r| Arc::ptr_eq(r, room)) {
            live.remove(key);
        }
    }

    /// Every room in `channel` that holds a state, by module id.
    pub(crate) fn in_channel(&self, channel: ChannelId) -> Vec<(String, Held)> {
        let rooms: Vec<(String, Arc<Room>)> = self
            .live()
            .iter()
            .filter(|(k, _)| k.channel_id == channel)
            .map(|(k, r)| (k.module_id.clone(), Arc::clone(r)))
            .collect();
        let mut out: Vec<(String, Held)> = rooms
            .into_iter()
            .map(|(id, room)| (id, room.held()))
            .filter(|(_, held)| held.state.is_some() && !held.ended)
            .collect();
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// Ends every room `which` picks; the ones that held a state, for telling viewers.
    pub(crate) fn end_where(
        &self,
        which: impl Fn(&RoomKey, &Held) -> bool,
        mut announce: impl FnMut(&RoomKey, &Held),
    ) -> Vec<(RoomKey, Held)> {
        let mut live = self.live();
        let picked: Vec<RoomKey> = live
            .iter()
            .filter(|(k, r)| which(k, &r.held()))
            .map(|(k, _)| k.clone())
            .collect();
        picked
            .into_iter()
            .filter_map(|key| {
                let room = live.remove(&key)?;
                room.finish(|held| announce(&key, held))
                    .map(|held| (key, held))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests;
