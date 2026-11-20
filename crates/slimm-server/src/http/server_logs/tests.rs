// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

fn semaphore() -> &'static Semaphore {
    Box::leak(Box::new(Semaphore::new(1)))
}

async fn settle() {
    for _ in 0..5 {
        tokio::task::yield_now().await;
    }
}

async fn after(seconds: u64) {
    tokio::time::advance(Duration::from_secs(seconds)).await;
    settle().await;
}

#[tokio::test(start_paused = true)]
async fn a_reader_that_takes_nothing_gives_the_turn_back_after_the_idle_limit() {
    let downloads = semaphore();
    let _turn = Turn::take(downloads.try_acquire().unwrap(), IDLE_LIMIT, TIME_LIMIT);
    after(29).await;
    assert_eq!(downloads.available_permits(), 0);
    after(2).await;
    assert_eq!(downloads.available_permits(), 1);
}

#[tokio::test(start_paused = true)]
async fn a_steady_reader_keeps_the_turn_until_the_time_limit() {
    let downloads = semaphore();
    let turn = Turn::take(downloads.try_acquire().unwrap(), IDLE_LIMIT, TIME_LIMIT);
    for _ in 0..17 {
        after(10).await;
        assert!(turn.read(Ok(Bytes::from_static(b"x"))).is_ok());
        assert_eq!(downloads.available_permits(), 0);
    }
    after(11).await;
    assert_eq!(downloads.available_permits(), 1);
    assert!(turn.read(Ok(Bytes::from_static(b"x"))).is_err());
}

#[tokio::test(start_paused = true)]
async fn a_dropped_body_gives_the_turn_back_at_once() {
    let downloads = semaphore();
    let turn = Turn::take(downloads.try_acquire().unwrap(), IDLE_LIMIT, TIME_LIMIT);
    drop(turn);
    settle().await;
    assert_eq!(downloads.available_permits(), 1);
}
