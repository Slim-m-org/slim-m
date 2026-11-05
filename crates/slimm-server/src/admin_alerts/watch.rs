// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The judgements behind each alert, as plain functions of what was observed so each can be
//! tested without a clock, a disk or a network.

use std::time::Duration;

use crate::store::SweepStatus;

/// How long LiveKit must stay unreachable before admins hear about it.
pub const LIVEKIT_GRACE_MS: i64 = 2 * 60 * 1000;

/// Consecutive sends the push relay never answered before it counts as failing.
pub const RELAY_FAILURE_LIMIT: u32 = 3;

/// A recorded sweep that has missed this many ticks in a row is failing.
pub const SWEEP_MISSED_TICKS: u32 = 3;

/// Remembers since when LiveKit has been unreachable.
#[derive(Debug, Default)]
pub struct LivekitWatch {
    unreachable_since_ms: Option<i64>,
}

impl LivekitWatch {
    /// `reachable` is `None` when no SFU is configured. Returns the problem once the outage has
    /// outlasted [`LIVEKIT_GRACE_MS`].
    pub fn observe(&mut self, now_ms: i64, reachable: Option<bool>) -> Option<String> {
        if reachable != Some(false) {
            self.unreachable_since_ms = None;
            return None;
        }
        let since = *self.unreachable_since_ms.get_or_insert(now_ms);
        (now_ms - since >= LIVEKIT_GRACE_MS)
            .then(|| "The voice server (LiveKit) has not answered for over 2 minutes.".to_owned())
    }
}

/// Free bytes on the filesystem holding `path`, or `None` when it cannot be read.
pub fn free_bytes(path: &std::path::Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: c_path is NUL-terminated and stat is a valid out-pointer for one statvfs.
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if rc != 0 {
        return None;
    }
    // SAFETY: statvfs returned 0, so it filled the struct.
    let stat = unsafe { stat.assume_init() };
    Some(stat.f_bavail.saturating_mul(stat.f_frsize))
}

/// The problem when `free` is under the threshold. A threshold of 0 turns the check off.
pub fn disk_problem(free: u64, min_free_mb: u64) -> Option<String> {
    let min_free = min_free_mb.saturating_mul(1024 * 1024);
    (min_free > 0 && free < min_free).then(|| {
        format!(
            "Only {} MB are free on the data disk; the alert threshold is {min_free_mb} MB.",
            free / (1024 * 1024)
        )
    })
}

/// Names the recorded sweeps that have missed [`SWEEP_MISSED_TICKS`] ticks.
///
/// A sweep records a run only when it succeeds, so missed ticks are failed passes. `uptime`
/// keeps a server that was just started, or down for a while, from blaming a sweep that has
/// not had its turns yet.
pub fn failing_sweeps(
    schedule: &[(&str, Duration)],
    recorded: &[SweepStatus],
    now_ms: i64,
    uptime: Duration,
) -> Vec<String> {
    schedule
        .iter()
        .filter_map(|(name, interval)| {
            let allowance = *interval * SWEEP_MISSED_TICKS;
            if uptime < allowance {
                return None;
            }
            let last = recorded
                .iter()
                .find(|sweep| sweep.name == *name)
                .map(|sweep| sweep.last_run_at);
            let overdue = last.is_none_or(|at| now_ms - at > allowance.as_millis() as i64);
            overdue.then(|| (*name).to_owned())
        })
        .collect()
}

/// The problem when the push relay has refused to answer [`RELAY_FAILURE_LIMIT`] sends in a row.
pub fn relay_problem(consecutive_failures: u32) -> Option<String> {
    (consecutive_failures >= RELAY_FAILURE_LIMIT).then(|| {
        format!("The push relay has not answered the last {consecutive_failures} notifications.")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: Duration = Duration::from_secs(3600);

    fn ran(name: &str, at: i64) -> SweepStatus {
        SweepStatus {
            name: name.to_owned(),
            last_run_at: at,
            last_reclaimed: 0,
        }
    }

    #[test]
    fn livekit_is_quiet_until_two_minutes_of_silence() {
        let mut watch = LivekitWatch::default();
        assert_eq!(watch.observe(0, Some(false)), None);
        assert_eq!(watch.observe(LIVEKIT_GRACE_MS - 1, Some(false)), None);
        assert!(watch.observe(LIVEKIT_GRACE_MS, Some(false)).is_some());
    }

    #[test]
    fn a_livekit_answer_restarts_the_clock() {
        let mut watch = LivekitWatch::default();
        watch.observe(0, Some(false));
        assert_eq!(watch.observe(60_000, Some(true)), None);
        assert_eq!(watch.observe(LIVEKIT_GRACE_MS, Some(false)), None);
    }

    #[test]
    fn no_sfu_is_never_an_outage() {
        let mut watch = LivekitWatch::default();
        assert_eq!(watch.observe(0, None), None);
        assert_eq!(watch.observe(i64::MAX / 2, None), None);
    }

    #[test]
    fn disk_alert_fires_below_the_threshold_only() {
        assert!(disk_problem(10 * 1024 * 1024, 100).is_some());
        assert_eq!(disk_problem(100 * 1024 * 1024, 100), None);
    }

    #[test]
    fn a_zero_threshold_turns_the_disk_alert_off() {
        assert_eq!(disk_problem(0, 0), None);
    }

    #[test]
    fn the_data_directory_reports_some_free_space() {
        assert!(free_bytes(&std::env::temp_dir()).is_some());
    }

    #[test]
    fn a_sweep_is_failing_after_three_missed_ticks() {
        let schedule = [("token", 6 * HOUR)];
        let now = 100 * 3_600_000;
        let stale = [ran("token", now - 19 * 3_600_000)];
        assert_eq!(failing_sweeps(&schedule, &stale, now, 30 * HOUR), ["token"]);
        let fresh = [ran("token", now - 17 * 3_600_000)];
        assert!(failing_sweeps(&schedule, &fresh, now, 30 * HOUR).is_empty());
    }

    #[test]
    fn a_young_process_does_not_blame_a_sweep() {
        let schedule = [("token", 6 * HOUR)];
        assert!(failing_sweeps(&schedule, &[], 0, HOUR).is_empty());
    }

    #[test]
    fn a_sweep_that_never_recorded_is_failing_once_it_has_had_its_turns() {
        let schedule = [("attachments", HOUR)];
        assert_eq!(failing_sweeps(&schedule, &[], 0, 4 * HOUR), ["attachments"]);
    }

    #[test]
    fn the_relay_needs_three_misses_in_a_row() {
        assert_eq!(relay_problem(2), None);
        assert!(relay_problem(3).is_some());
    }
}
