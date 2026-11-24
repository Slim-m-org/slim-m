// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The version a live reaction or poll tally frame carries, so a client keeps the newest one.
//!
//! Taken after the write commits and before the tally is read (or under the write
//! lock), a larger version always describes a tally that includes every write
//! committed before the smaller one was taken. Unix microseconds, pushed one
//! past the last value when the clock has not moved, so it also keeps rising
//! across a restart without anything stored.

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static LAST: AtomicI64 = AtomicI64::new(0);

/// The next tally version: strictly greater than every one this process handed out.
pub fn next_tally_version() -> i64 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros() as i64)
        .unwrap_or(0);
    let previous = LAST
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |last| {
            Some(now.max(last + 1))
        })
        .unwrap_or_else(|last| last);
    now.max(previous + 1)
}

#[cfg(test)]
mod tests {
    use super::next_tally_version;

    #[test]
    fn every_version_is_larger_than_the_last() {
        let mut last = next_tally_version();
        for _ in 0..10_000 {
            let next = next_tally_version();
            assert!(next > last, "{next} did not follow {last}");
            last = next;
        }
    }
}
