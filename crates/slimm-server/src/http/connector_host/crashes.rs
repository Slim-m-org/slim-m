// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Restart with backoff and the crash breaker for host-run connectors (decision 0134): start
//! again after 1 s, doubling to 5 minutes, and turn off after 5 crashes within 10 minutes.

use std::collections::VecDeque;

pub const FIRST_DELAY_MS: i64 = 1_000;
pub const MAX_DELAY_MS: i64 = 5 * 60 * 1_000;
pub const CRASH_LIMIT: usize = 5;
pub const WINDOW_MS: i64 = 10 * 60 * 1_000;

/// What to do about an exited connector right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Disable { crashes: usize },
    StartNow,
    Wait,
}

/// One connector's recent crashes, told apart by the exit time the supervisor reports.
#[derive(Debug, Default, Clone)]
pub struct CrashLog {
    crashes: VecDeque<i64>,
    last_exit: Option<String>,
    restart_at: i64,
}

impl CrashLog {
    /// Counts a new exit once, then answers whether its backoff has passed.
    pub fn on_exited(&mut self, finished_at: &str, now: i64) -> Decision {
        if self.last_exit.as_deref() != Some(finished_at) {
            self.last_exit = Some(finished_at.to_owned());
            self.crashes.push_back(now);
            while self.crashes.front().is_some_and(|&t| now - t > WINDOW_MS) {
                self.crashes.pop_front();
            }
            if self.crashes.len() >= CRASH_LIMIT {
                return Decision::Disable {
                    crashes: self.crashes.len(),
                };
            }
            self.restart_at = now + delay_for(self.crashes.len());
        }
        if now >= self.restart_at {
            Decision::StartNow
        } else {
            Decision::Wait
        }
    }

    pub fn restarts(&self) -> usize {
        self.crashes.len()
    }
}

/// Backoff for a create or start that failed for a reason other than a crash, so a
/// supervisor that keeps failing is not asked (and a token not minted) every tick.
#[derive(Debug, Default, Clone, Copy)]
pub struct Retry {
    next_at: i64,
    delay: i64,
}

impl Retry {
    pub fn due(&self, now: i64) -> bool {
        now >= self.next_at
    }

    pub fn failed(&mut self, now: i64) {
        self.delay = if self.delay == 0 {
            FIRST_DELAY_MS
        } else {
            (self.delay * 2).min(MAX_DELAY_MS)
        };
        self.next_at = now + self.delay;
    }
}

/// 1 s for the first crash in the window, doubling, never past 5 minutes.
pub fn delay_for(crashes_in_window: usize) -> i64 {
    let doublings = crashes_in_window.saturating_sub(1).min(20) as u32;
    (FIRST_DELAY_MS << doublings).min(MAX_DELAY_MS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_delay_doubles_from_a_second_to_five_minutes() {
        assert_eq!(delay_for(1), 1_000);
        assert_eq!(delay_for(2), 2_000);
        assert_eq!(delay_for(4), 8_000);
        assert_eq!(delay_for(30), MAX_DELAY_MS);
    }

    #[test]
    fn a_crash_waits_out_its_backoff_and_counts_once() {
        let mut log = CrashLog::default();
        assert_eq!(log.on_exited("t1", 0), Decision::Wait);
        assert_eq!(log.on_exited("t1", 500), Decision::Wait);
        assert_eq!(log.on_exited("t1", 1_000), Decision::StartNow);
        assert_eq!(log.restarts(), 1);
        assert_eq!(log.on_exited("t2", 2_000), Decision::Wait);
        assert_eq!(log.on_exited("t2", 3_999), Decision::Wait);
        assert_eq!(log.on_exited("t2", 4_000), Decision::StartNow);
    }

    #[test]
    fn five_crashes_in_ten_minutes_disable() {
        let mut log = CrashLog::default();
        for i in 0..4 {
            assert_ne!(
                log.on_exited(&format!("t{i}"), i * 60_000),
                Decision::Disable { crashes: 5 }
            );
        }
        assert_eq!(
            log.on_exited("t4", 4 * 60_000),
            Decision::Disable { crashes: 5 }
        );
    }

    #[test]
    fn a_failing_create_backs_off_to_five_minutes() {
        let mut retry = Retry::default();
        assert!(retry.due(0));
        retry.failed(0);
        assert!(!retry.due(999) && retry.due(1_000));
        for _ in 0..20 {
            retry.failed(0);
        }
        assert!(!retry.due(MAX_DELAY_MS - 1) && retry.due(MAX_DELAY_MS));
    }

    #[test]
    fn crashes_older_than_the_window_fall_away() {
        let mut log = CrashLog::default();
        for i in 0..4 {
            log.on_exited(&format!("t{i}"), i * 1_000);
        }
        assert_eq!(log.on_exited("late", WINDOW_MS + 4_000), Decision::Wait);
        assert_eq!(log.restarts(), 1);
    }
}
