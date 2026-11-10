// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The wait-first, keep-ticking shape every background sweep shares.

use std::future::{Ready, ready};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use super::spawn_sweep;

const EVERY: Duration = Duration::from_secs(3600);

fn counting(runs: &Arc<AtomicUsize>) -> impl Fn() -> Ready<()> + Send + 'static {
    let runs = Arc::clone(runs);
    move || {
        runs.fetch_add(1, Ordering::SeqCst);
        ready(())
    }
}

/// Lets the spawned sweep run until it parks on its timer again.
async fn settle() {
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
}

async fn elapse(span: Duration) {
    tokio::time::advance(span).await;
    settle().await;
}

#[tokio::test(start_paused = true)]
async fn a_sweep_waits_out_its_first_interval_instead_of_running_at_boot() {
    let runs = Arc::new(AtomicUsize::new(0));
    spawn_sweep(EVERY, counting(&runs));

    settle().await;
    assert_eq!(runs.load(Ordering::SeqCst), 0, "ran at boot");

    elapse(EVERY - Duration::from_secs(1)).await;
    assert_eq!(runs.load(Ordering::SeqCst), 0, "ran before its interval");

    elapse(Duration::from_secs(1)).await;
    assert_eq!(runs.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn a_sweep_runs_once_per_interval_and_keeps_ticking() {
    let runs = Arc::new(AtomicUsize::new(0));
    spawn_sweep(EVERY, counting(&runs));
    settle().await;

    for expected in 1..=4 {
        elapse(EVERY).await;
        assert_eq!(runs.load(Ordering::SeqCst), expected);
    }
}
