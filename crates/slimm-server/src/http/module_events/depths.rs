// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How many pushed events each module has waiting, for the admin's Dock screen. The queue itself
//! lives in `queue.rs` and keeps this current; this is only the readable copy.

use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Default)]
pub struct QueueDepths {
    depths: Mutex<HashMap<String, usize>>,
}

impl QueueDepths {
    /// Records `depth` for `module_id`; a module with nothing waiting is not listed.
    pub(super) fn set(&self, module_id: &str, depth: usize) {
        let mut depths = self.lock();
        if depth == 0 {
            depths.remove(module_id);
        } else {
            depths.insert(module_id.to_owned(), depth);
        }
    }

    /// Events waiting for `module_id` right now.
    pub fn get(&self, module_id: &str) -> usize {
        self.lock().get(module_id).copied().unwrap_or(0)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, usize>> {
        self.depths
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_depth_is_read_back_and_zero_forgets_the_module() {
        let depths = QueueDepths::default();
        assert_eq!(depths.get("m"), 0);
        depths.set("m", 3);
        assert_eq!(depths.get("m"), 3);
        depths.set("m", 0);
        assert_eq!(depths.get("m"), 0);
        assert!(depths.lock().is_empty());
    }
}
