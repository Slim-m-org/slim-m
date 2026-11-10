// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which modules take each event, read once per module change rather than once per event.

use std::collections::HashMap;
use std::sync::Arc;

use crate::store::{EventCandidate, Store};

/// Candidates by event name, valid for one `Store::module_epoch`; owned by the one consumer task.
#[derive(Default)]
pub(super) struct Candidates {
    epoch: Option<u64>,
    by_event: HashMap<&'static str, Arc<[EventCandidate]>>,
}

impl Candidates {
    pub(super) async fn of(
        &mut self,
        store: &Store,
        event: &'static str,
    ) -> anyhow::Result<Arc<[EventCandidate]>> {
        // Read before the query, so a change landing mid-read leaves this one epoch behind and re-read.
        let epoch = store.module_epoch();
        if self.epoch != Some(epoch) {
            self.by_event.clear();
            self.epoch = Some(epoch);
        }
        if let Some(known) = self.by_event.get(event) {
            return Ok(known.clone());
        }
        let read: Arc<[EventCandidate]> = store.module_event_candidates(event).await?.into();
        self.by_event.insert(event, read.clone());
        Ok(read)
    }
}
