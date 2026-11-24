// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The wait-first, keep-ticking shape every background sweep shares.

use std::future::{Ready, ready};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use super::{OVERDUE_START_DELAY, first_delay, spawn_sweep, spawn_sweep_after};

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

const NOW: i64 = 1_000_000_000_000;

#[test]
fn a_sweep_that_never_ran_is_due_shortly_after_boot() {
    assert_eq!(first_delay(None, NOW, EVERY), OVERDUE_START_DELAY);
}

#[test]
fn an_overdue_sweep_is_due_shortly_after_boot() {
    let last = NOW - 2 * EVERY.as_millis() as i64;
    assert_eq!(first_delay(Some(last), NOW, EVERY), OVERDUE_START_DELAY);
}

#[test]
fn a_recent_run_waits_out_only_the_remainder() {
    let last = NOW - 40 * 60 * 1000;
    assert_eq!(
        first_delay(Some(last), NOW, EVERY),
        Duration::from_secs(20 * 60)
    );
}

#[test]
fn a_run_stamped_in_the_future_never_waits_longer_than_an_interval() {
    assert_eq!(first_delay(Some(NOW + 10 * 3_600_000), NOW, EVERY), EVERY);
}

#[tokio::test(start_paused = true)]
async fn an_overdue_sweep_runs_after_the_start_delay_then_on_its_interval() {
    let runs = Arc::new(AtomicUsize::new(0));
    let delay = first_delay(None, NOW, EVERY);
    spawn_sweep_after(std::future::ready(delay), EVERY, counting(&runs));

    settle().await;
    assert_eq!(runs.load(Ordering::SeqCst), 0);
    elapse(OVERDUE_START_DELAY).await;
    assert_eq!(
        runs.load(Ordering::SeqCst),
        1,
        "the overdue sweep did not run"
    );
    elapse(EVERY).await;
    assert_eq!(runs.load(Ordering::SeqCst), 2);
}
