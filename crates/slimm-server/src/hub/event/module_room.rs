// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The payload of [`super::Event::ModuleRoomChanged`]: one module's shared room
//! state in one channel (decision 0131), the same for every viewer.

use std::sync::Arc;

use serde::{Serialize, Serializer};
use serde_json::value::RawValue;

use crate::ids::ChannelId;

/// A module's state as the JSON it answered, shared by every frame and read that carries it.
#[derive(Debug, Clone)]
pub struct RoomJson(Arc<Box<RawValue>>);

impl RoomJson {
    pub fn new(raw: Box<RawValue>) -> Self {
        Self(Arc::new(raw))
    }

    /// The compact JSON text, as the module's state was stored.
    pub fn get(&self) -> &str {
        self.0.get()
    }
}

impl Serialize for RoomJson {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        (**self.0).serialize(serializer)
    }
}

/// A room's state changed, or the room ended when `state` is `None`.
#[derive(Debug, Clone)]
pub struct ModuleRoomChange {
    pub channel_id: ChannelId,
    pub module_id: String,
    pub seq: u64,
    pub state: Option<RoomJson>,
    /// The `scene/1` the module drew from `state`, when it drew one (decision 0132).
    pub scene: Option<RoomJson>,
    /// Why the room ended: `ended`, `call_ended`, `idle`, `module_off` or `channel_removed`.
    pub ended: Option<&'static str>,
}
