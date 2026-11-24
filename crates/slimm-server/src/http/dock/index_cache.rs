// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Keeps the official index for a few minutes, so listing installed modules does not fetch it every time.

use std::future::Future;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use super::manifest::IndexEntry;

const KEEP: Duration = Duration::from_secs(5 * 60);
/// A failed fetch is remembered briefly, so an unreachable registry costs one timeout, not one per open.
const KEEP_FAILED: Duration = Duration::from_secs(60);

type Slot = Mutex<Option<(Instant, Duration, Vec<IndexEntry>)>>;

static OFFICIAL: Slot = Mutex::new(None);

/// The official index, fetched by `fetch` only when the kept copy is missing or stale.
pub(super) async fn official<F>(fetch: F) -> Vec<IndexEntry>
where
    F: Future<Output = Option<Vec<IndexEntry>>>,
{
    kept_or(&OFFICIAL, fetch).await
}

async fn kept_or<F>(slot: &Slot, fetch: F) -> Vec<IndexEntry>
where
    F: Future<Output = Option<Vec<IndexEntry>>>,
{
    let fresh = {
        let guard = slot
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard
            .as_ref()
            .filter(|(at, keep, _)| at.elapsed() < *keep)
            .map(|(_, _, index)| index.clone())
    };
    if let Some(index) = fresh {
        return index;
    }
    let fetched = fetch.await;
    let keep = if fetched.is_some() { KEEP } else { KEEP_FAILED };
    let index = fetched.unwrap_or_default();
    *slot
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) =
        Some((Instant::now(), keep, index.clone()));
    index
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    #[tokio::test]
    async fn a_second_listing_reuses_the_fetched_index_and_a_failure_is_kept_too() {
        let slot: Slot = Mutex::new(None);
        let fetches = AtomicUsize::new(0);
        let fetch = || async {
            fetches.fetch_add(1, Ordering::SeqCst);
            None
        };
        kept_or(&slot, fetch()).await;
        kept_or(&slot, fetch()).await;
        assert_eq!(fetches.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_stale_copy_is_fetched_again() {
        let slot: Slot = Mutex::new(Some((
            Instant::now() - KEEP - Duration::from_secs(1),
            KEEP,
            Vec::new(),
        )));
        let fetches = AtomicUsize::new(0);
        kept_or(&slot, async {
            fetches.fetch_add(1, Ordering::SeqCst);
            Some(Vec::new())
        })
        .await;
        assert_eq!(fetches.load(Ordering::SeqCst), 1);
    }
}
