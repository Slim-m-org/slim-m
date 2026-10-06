// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deployment-wide cursor over moderation events, so a consumer that was
//! offline can tell it missed some without being handed any history.
//!
//! The five events `member.timeout`, `member.removed`, `member.restored`,
//! `member.role_changed` and `role.changed` are delivered to every connection
//! and have no per-channel stream a `/sync` scope could resume. Each is
//! stamped here with a strictly increasing number, and the connect `hello`
//! carries the current head. A consumer that persists the last number it saw
//! compares it to the head on reconnect: a larger head means events landed
//! while it was away.
//!
//! The number is clock-seeded rather than stored: it starts at boot time and
//! never repeats or decreases, so it stays monotonic across restarts without a
//! table. The price is one conservative signal after each restart, since the
//! head is then the boot time, which is later than anything a consumer saw
//! before. That is the safe direction for an audit trail: "you may have
//! missed events" when unsure, never silence.
//!
//! A backward clock step across a restart can make the head smaller than a
//! number a consumer already saw, a silent false negative this does not guard
//! against. The `hello` also hands the head to every connection, so any member
//! learns roughly when the last moderation event happened; that is accepted.
//!
//! Nothing here exposes what happened. The number carries no permission, so
//! the gates on `GET /roles`, `/reports/history` and `/members/removed` stay
//! exactly as they were.

use std::sync::atomic::{AtomicU64, Ordering};

use super::Event;

pub(super) struct ModerationClock {
    last: AtomicU64,
}

impl ModerationClock {
    pub(super) fn new() -> Self {
        Self {
            last: AtomicU64::new(now_ms()),
        }
    }

    pub(super) fn head(&self) -> u64 {
        self.last.load(Ordering::Acquire)
    }

    pub(super) fn advance(&self) -> u64 {
        let now = now_ms();
        let mut last = self.last.load(Ordering::Acquire);
        // A compare-exchange loop rather than `fetch_update`, which newer toolchains deprecate for `try_update`.
        loop {
            let next = now.max(last + 1);
            match self
                .last
                .compare_exchange_weak(last, next, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => return next,
                Err(actual) => last = actual,
            }
        }
    }
}

fn now_ms() -> u64 {
    u64::try_from(crate::store::now_ms()).unwrap_or(0)
}

/// Whether this event belongs to the moderation trail and so carries a number.
pub(super) fn is_moderation(event: &Event) -> bool {
    matches!(
        event,
        Event::MemberTimeoutChanged { .. }
            | Event::MemberRemoved(_)
            | Event::MemberRestored(_)
            | Event::MemberRoleChanged { .. }
            | Event::RoleChanged { .. }
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tight_loop_never_repeats_or_goes_backwards() {
        let clock = ModerationClock::new();
        let mut previous = clock.head();
        for _ in 0..10_000 {
            let next = clock.advance();
            assert!(next > previous);
            previous = next;
        }
        assert_eq!(clock.head(), previous);
    }

    #[test]
    fn concurrent_callers_never_get_the_same_value() {
        let clock = std::sync::Arc::new(ModerationClock::new());
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let clock = clock.clone();
                std::thread::spawn(move || (0..2_000).map(|_| clock.advance()).collect::<Vec<_>>())
            })
            .collect();
        let mut all: Vec<u64> = handles
            .into_iter()
            .flat_map(|handle| handle.join().unwrap())
            .collect();
        let total = all.len();
        all.sort_unstable();
        all.dedup();
        assert_eq!(
            all.len(),
            total,
            "two callers were handed one sequence value"
        );
        assert_eq!(clock.head(), *all.last().unwrap());
    }
}
