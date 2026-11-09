// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One upstream fetch shared by every request that asks for the same key while it runs.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::sync::OnceCell;

struct Entry<T> {
    cell: Arc<OnceCell<T>>,
    waiters: usize,
}

/// The fetches currently running, keyed by what they fetch.
pub(super) struct Flights<T> {
    entries: Mutex<HashMap<String, Entry<T>>>,
}

impl<T> Flights<T> {
    pub(super) fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }

    /// Joins the fetch for [key], starting one when none is running.
    pub(super) fn join(&self, key: &str) -> Flight<'_, T> {
        let mut entries = self.lock();
        let entry = entries.entry(key.to_owned()).or_insert_with(|| Entry {
            cell: Arc::default(),
            waiters: 0,
        });
        entry.waiters += 1;
        Flight {
            flights: self,
            key: key.to_owned(),
            cell: entry.cell.clone(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<String, Entry<T>>> {
        match self.entries.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    #[cfg(test)]
    fn running(&self) -> usize {
        self.lock().len()
    }
}

/// A request's place in a fetch.
///
/// Dropping it leaves the fetch once nobody else waits on it, so a request
/// cancelled mid-fetch cleans up the same as one that finished.
pub(super) struct Flight<'a, T> {
    flights: &'a Flights<T>,
    key: String,
    cell: Arc<OnceCell<T>>,
}

impl<T> Flight<'_, T> {
    pub(super) fn cell(&self) -> &OnceCell<T> {
        &self.cell
    }
}

impl<T> Drop for Flight<'_, T> {
    fn drop(&mut self) {
        let mut entries = self.flights.lock();
        if let Some(entry) = entries.get_mut(&self.key) {
            entry.waiters -= 1;
            if entry.waiters == 0 {
                entries.remove(&self.key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn requests_for_one_key_share_a_cell_until_the_last_leaves() {
        let flights = Flights::<u8>::new();
        let first = flights.join("a");
        let second = flights.join("a");
        assert!(std::ptr::eq(first.cell(), second.cell()));
        drop(first);
        let third = flights.join("a");
        assert!(std::ptr::eq(second.cell(), third.cell()));
        drop((second, third));
        assert_eq!(flights.running(), 0);
    }

    #[test]
    fn a_new_request_after_the_last_left_starts_a_fresh_fetch() {
        let flights = Flights::<u8>::new();
        let first = flights.join("a");
        first.cell().set(1).unwrap();
        drop(first);
        assert_eq!(flights.join("a").cell().get(), None);
    }

    #[tokio::test]
    async fn a_request_cancelled_mid_fetch_leaves_nothing_behind() {
        let flights = Arc::new(Flights::<u8>::new());
        let request = tokio::spawn({
            let flights = flights.clone();
            async move {
                let flight = flights.join("https://slow.example/");
                flight.cell().get_or_init(std::future::pending).await;
            }
        });
        while flights.running() == 0 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        request.abort();
        let _ = request.await;
        assert_eq!(flights.running(), 0);
    }
}
