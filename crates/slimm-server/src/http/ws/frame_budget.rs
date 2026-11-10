// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A per-connection budget for inbound frames of any kind, so a client looping on a frame
//! type with no limiter of its own (`ping`, `active`, `viewing`) cannot pin the presence lock.

use std::time::Instant;

/// Sustained frames per second. The busiest honest client (a drawer with a cursor, a stroke
/// and a followed view going) sends well under half of this.
const REFILL_PER_SECOND: f64 = 100.0;

/// The burst a connection may spend before frames are refused.
const BURST: f64 = 200.0;

/// How far past empty a flood may run, refused frame by refused frame, before the socket is closed.
const OVERDRAFT: f64 = 100.0;

/// What to do with one inbound frame.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Verdict {
    Allow,
    Refuse,
    Close,
}

pub(super) struct FrameBudget {
    tokens: f64,
    refilled_at: Instant,
}

impl FrameBudget {
    pub(super) fn new(now: Instant) -> Self {
        Self {
            tokens: BURST,
            refilled_at: now,
        }
    }

    /// Charges one frame. A refused frame still costs, so sending faster than the refill digs toward `Close`.
    pub(super) fn take(&mut self, now: Instant) -> Verdict {
        let elapsed = now.saturating_duration_since(self.refilled_at);
        self.refilled_at = now;
        self.tokens = (self.tokens + elapsed.as_secs_f64() * REFILL_PER_SECOND).min(BURST);
        self.tokens -= 1.0;
        if self.tokens >= 0.0 {
            Verdict::Allow
        } else if self.tokens >= -OVERDRAFT {
            Verdict::Refuse
        } else {
            Verdict::Close
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    const FRAME_GAP: Duration = Duration::from_millis(10);

    fn drain(budget: &mut FrameBudget, now: Instant, frames: usize) -> Vec<Verdict> {
        (0..frames).map(|_| budget.take(now)).collect()
    }

    #[test]
    fn an_honest_pace_never_runs_dry() {
        let start = Instant::now();
        let mut budget = FrameBudget::new(start);
        for frame in 0..10_000u32 {
            assert_eq!(budget.take(start + FRAME_GAP * frame), Verdict::Allow);
        }
    }

    #[test]
    fn a_burst_is_allowed_then_refused_then_closed() {
        let start = Instant::now();
        let mut budget = FrameBudget::new(start);
        let verdicts = drain(&mut budget, start, 400);
        assert!(verdicts[..200].iter().all(|v| *v == Verdict::Allow));
        assert!(verdicts[200..300].iter().all(|v| *v == Verdict::Refuse));
        assert!(verdicts[300..].iter().all(|v| *v == Verdict::Close));
    }

    #[test]
    fn a_pause_refills_the_budget() {
        let start = Instant::now();
        let mut budget = FrameBudget::new(start);
        drain(&mut budget, start, 250);
        let later = start + Duration::from_secs(5);
        assert_eq!(budget.take(later), Verdict::Allow);
    }

    #[test]
    fn a_sustained_flood_above_the_refill_ends_in_a_close() {
        let start = Instant::now();
        let mut budget = FrameBudget::new(start);
        let gap = Duration::from_millis(2);
        let closed = (0..2_000u32).any(|frame| budget.take(start + gap * frame) == Verdict::Close);
        assert!(closed);
    }
}
