// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How many streamed responses one caller may hold open at once.
//!
//! A rate class meters how fast requests start; a slow reader of a large body
//! keeps its file handle and task for as long as it likes, so the count of
//! bodies still open is capped separately.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

/// The open streams per caller key, shared by every clone.
#[derive(Clone, Default)]
pub(super) struct StreamSlots {
    open: Arc<Mutex<HashMap<String, usize>>>,
}

/// One open stream, released when dropped.
pub struct StreamPermit {
    slots: StreamSlots,
    key: String,
}

impl StreamSlots {
    fn lock(&self) -> MutexGuard<'_, HashMap<String, usize>> {
        self.open
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub(super) fn acquire(&self, key: &str, cap: usize) -> Option<StreamPermit> {
        let mut open = self.lock();
        let held = open.entry(key.to_owned()).or_default();
        if *held >= cap {
            return None;
        }
        *held += 1;
        Some(StreamPermit {
            slots: self.clone(),
            key: key.to_owned(),
        })
    }
}

impl Drop for StreamPermit {
    fn drop(&mut self) {
        let mut open = self.slots.lock();
        if let Some(held) = open.get_mut(&self.key) {
            *held -= 1;
            if *held == 0 {
                open.remove(&self.key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_caller_is_held_to_its_cap_and_a_release_frees_a_slot() {
        let slots = StreamSlots::default();
        let first = slots.acquire("a", 2).unwrap();
        let _second = slots.acquire("a", 2).unwrap();
        assert!(slots.acquire("a", 2).is_none());
        assert!(
            slots.acquire("b", 2).is_some(),
            "another caller is unaffected"
        );
        drop(first);
        assert!(slots.acquire("a", 2).is_some());
    }

    #[test]
    fn released_keys_do_not_accumulate() {
        let slots = StreamSlots::default();
        drop(slots.acquire("a", 1).unwrap());
        assert!(slots.lock().is_empty());
    }
}
