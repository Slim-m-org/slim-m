// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounded polling for "until X happens", so a test waits on the effect and not on a guess.

use std::future::Future;
use std::time::{Duration, Instant};

/// Generous on purpose: a loaded runner only costs time when the effect really is late.
pub const TIMEOUT: Duration = Duration::from_secs(5);
const POLL: Duration = Duration::from_millis(10);

/// Polls `probe` until it yields a value or `timeout` passes.
pub async fn poll<T, F, Fut>(timeout: Duration, mut probe: F) -> Option<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Option<T>>,
{
    let start = Instant::now();
    loop {
        if let Some(found) = probe().await {
            return Some(found);
        }
        if start.elapsed() > timeout {
            return None;
        }
        tokio::time::sleep(POLL).await;
    }
}

/// Like [`poll`], but a miss fails the test naming what never happened.
pub async fn wait_for<T, F, Fut>(what: &str, probe: F) -> T
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Option<T>>,
{
    match poll(TIMEOUT, probe).await {
        Some(found) => found,
        None => panic!("{what} never happened within {TIMEOUT:?}"),
    }
}

/// Waits for a synchronous condition to hold.
pub async fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
    wait_for(what, || {
        let held = cond();
        async move { held.then_some(()) }
    })
    .await;
}

/// Waits for an asynchronous condition (a store query, say) to hold.
pub async fn wait_until_async<F, Fut>(what: &str, mut cond: F)
where
    F: FnMut() -> Fut,
    Fut: Future<Output = bool>,
{
    wait_for(what, || {
        let held = cond();
        async move { held.await.then_some(()) }
    })
    .await;
}

/// Like [`wait_until`], but reports a miss to the caller instead of failing.
pub async fn holds_within(timeout: Duration, mut cond: impl FnMut() -> bool) -> bool {
    poll(timeout, || {
        let held = cond();
        async move { held.then_some(()) }
    })
    .await
    .is_some()
}

/// Like [`holds_within`] for an asynchronous condition.
pub async fn holds_within_async<F, Fut>(timeout: Duration, mut cond: F) -> bool
where
    F: FnMut() -> Fut,
    Fut: Future<Output = bool>,
{
    poll(timeout, || {
        let held = cond();
        async move { held.await.then_some(()) }
    })
    .await
    .is_some()
}
