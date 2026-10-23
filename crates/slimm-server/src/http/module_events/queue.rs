// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Each module's pending events: a bounded queue that drops the oldest first
//! and counts what it dropped, served round-robin with at most one event of a
//! module in flight so a module sees its events in order.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};

use tokio::sync::Notify;

/// Events held per module before the oldest is dropped.
pub(super) const QUEUE_CAPACITY: usize = 256;

/// One event for one module, already rendered as the run's input text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Job {
    pub(super) module_id: String,
    pub(super) kind: &'static str,
    pub(super) body: Arc<str>,
}

#[derive(Default)]
struct State {
    queues: HashMap<String, VecDeque<(&'static str, Arc<str>)>>,
    /// Modules with something queued and nothing in flight, in service order.
    ready: VecDeque<String>,
    running: HashSet<String>,
    dropped: HashMap<String, u64>,
}

pub(super) struct Queues {
    state: Mutex<State>,
    capacity: usize,
    wake: Notify,
}

impl Queues {
    pub(super) fn new(capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::default(),
            capacity,
            wake: Notify::new(),
        })
    }

    /// Queues `body` for `module_id`; returns true when the oldest event was dropped to fit it.
    pub(super) fn push(&self, module_id: &str, kind: &'static str, body: Arc<str>) -> bool {
        let mut guard = self.lock();
        let state = &mut *guard;
        let queue = state.queues.entry(module_id.to_owned()).or_default();
        let was_empty = queue.is_empty();
        let dropped = queue.len() >= self.capacity;
        if dropped {
            queue.pop_front();
        }
        queue.push_back((kind, body));
        if dropped {
            *state.dropped.entry(module_id.to_owned()).or_default() += 1;
        } else if was_empty && !state.running.contains(module_id) {
            state.ready.push_back(module_id.to_owned());
        }
        drop(guard);
        self.wake.notify_one();
        dropped
    }

    /// The next event to run, marking its module in flight until [`Self::finish`].
    pub(super) fn take(&self) -> Option<Job> {
        let mut state = self.lock();
        let module_id = state.ready.pop_front()?;
        let (kind, body) = state.queues.get_mut(&module_id)?.pop_front()?;
        state.running.insert(module_id.clone());
        Some(Job {
            module_id,
            kind,
            body,
        })
    }

    pub(super) fn finish(&self, module_id: &str) {
        let mut state = self.lock();
        state.running.remove(module_id);
        if state.queues.get(module_id).is_some_and(|q| !q.is_empty()) {
            state.ready.push_back(module_id.to_owned());
            drop(state);
            self.wake.notify_one();
        }
    }

    /// Drops everything queued for a module that can no longer receive it.
    pub(super) fn clear(&self, module_id: &str) {
        let mut state = self.lock();
        state.queues.remove(module_id);
        state.ready.retain(|m| m != module_id);
    }

    /// Drops counted since the last call, to be stored.
    pub(super) fn take_dropped(&self) -> Vec<(String, u64)> {
        self.lock().dropped.drain().collect()
    }

    pub(super) async fn work_available(&self) {
        self.wake.notified().await;
    }

    #[cfg(test)]
    pub(super) fn len(&self, module_id: &str) -> usize {
        self.lock().queues.get(module_id).map_or(0, VecDeque::len)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(n: usize) -> Arc<str> {
        Arc::from(n.to_string())
    }

    #[test]
    fn a_full_queue_drops_the_oldest_and_counts_it() {
        let queues = Queues::new(3);
        let dropped: Vec<bool> = (0..5).map(|n| queues.push("m", "k", body(n))).collect();
        assert_eq!(dropped, [false, false, false, true, true]);
        assert_eq!(queues.len("m"), 3);
        assert_eq!(queues.take_dropped(), vec![("m".to_owned(), 2)]);
        assert!(queues.take_dropped().is_empty(), "counted once");
        let first = queues.take().expect("a job");
        assert_eq!(&*first.body, "2", "events 0 and 1 were the oldest");
    }

    #[test]
    fn a_module_runs_one_event_at_a_time_and_in_order() {
        let queues = Queues::new(8);
        queues.push("m", "k", body(1));
        queues.push("m", "k", body(2));
        let first = queues.take().expect("first");
        assert_eq!(&*first.body, "1");
        assert!(queues.take().is_none(), "second waits for the first");
        queues.finish("m");
        assert_eq!(&*queues.take().expect("second").body, "2");
    }

    #[test]
    fn modules_take_turns() {
        let queues = Queues::new(8);
        for n in 0..3 {
            queues.push("a", "k", body(n));
        }
        queues.push("b", "k", body(9));
        let order: Vec<String> = (0..2)
            .map(|_| {
                let job = queues.take().expect("job");
                queues.finish(&job.module_id);
                job.module_id
            })
            .collect();
        assert_eq!(order, ["a", "b"]);
    }

    #[test]
    fn clearing_a_module_forgets_its_events() {
        let queues = Queues::new(8);
        queues.push("a", "k", body(1));
        queues.clear("a");
        assert!(queues.take().is_none());
    }
}
