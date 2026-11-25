// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The open-file limit the process runs under.
//!
//! Rust keeps the soft `RLIMIT_NOFILE` it inherits, and a container commonly
//! starts with a soft limit of 1024 under a far higher hard one. Every socket,
//! pooled database connection and open attachment spends one, so the server
//! raises the soft limit to the hard one at startup and sizes its connection
//! cap from what it was granted.

/// A soft limit above this is never requested; some runtimes report a hard limit near `2^30`.
const SOFT_CEILING: u64 = 1 << 20;

/// Descriptors kept back from the connection cap for files, database handles and outbound sockets.
const RESERVED: u64 = 256;

/// The open-file limits in force once [`raise`] has run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FdLimit {
    /// The soft limit before the raise.
    pub inherited: u64,
    /// The soft limit now in force.
    pub soft: u64,
    /// The hard limit, the most the soft one can reach.
    pub hard: u64,
}

impl FdLimit {
    /// How many connections fit under the soft limit, never more than `ceiling`.
    pub fn connection_cap(self, ceiling: usize) -> usize {
        let room = self.soft.saturating_sub(RESERVED).max(1);
        usize::try_from(room).map_or(ceiling, |room| room.min(ceiling))
    }
}

fn target(soft: u64, hard: u64) -> u64 {
    hard.min(SOFT_CEILING).max(soft)
}

/// `rlim_t` is 32 bits wide on some targets, so this widens it everywhere.
#[cfg(unix)]
#[allow(clippy::useless_conversion)]
fn widen(value: libc::rlim_t) -> u64 {
    u64::from(value)
}

/// Raises the soft open-file limit as far as the hard one allows; `None` when it cannot be read.
#[cfg(unix)]
pub fn raise() -> Option<FdLimit> {
    let mut current = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `current` is a valid rlimit that outlives the call.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut current) } != 0 {
        return None;
    }
    let inherited = widen(current.rlim_cur);
    let hard = widen(current.rlim_max);
    let wanted = target(inherited, hard);
    if wanted > inherited {
        let raised = libc::rlimit {
            rlim_cur: wanted as libc::rlim_t,
            rlim_max: current.rlim_max,
        };
        // SAFETY: `raised` is a valid rlimit that outlives the call.
        if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raised) } != 0 {
            return Some(FdLimit {
                inherited,
                soft: inherited,
                hard,
            });
        }
    }
    Some(FdLimit {
        inherited,
        soft: wanted,
        hard,
    })
}

#[cfg(not(unix))]
pub fn raise() -> Option<FdLimit> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_soft_limit_rises_to_the_hard_one() {
        assert_eq!(target(1024, 524_288), 524_288);
    }

    #[test]
    fn an_unbounded_hard_limit_is_capped() {
        assert_eq!(target(1024, 1 << 30), SOFT_CEILING);
    }

    #[test]
    fn a_soft_limit_already_above_the_target_is_left_alone() {
        assert_eq!(target(4_000_000, 4_000_000), 4_000_000);
    }

    #[test]
    fn the_connection_cap_leaves_room_for_files() {
        let low = FdLimit {
            inherited: 1024,
            soft: 1024,
            hard: 1024,
        };
        assert_eq!(low.connection_cap(8192), 768);
        let high = FdLimit {
            soft: 65_536,
            ..low
        };
        assert_eq!(high.connection_cap(8192), 8192);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn raise_lifts_a_low_soft_limit_in_this_process() {
        let mut limit = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        // SAFETY: `limit` is a valid rlimit that outlives the calls.
        unsafe {
            libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit);
            limit.rlim_cur = 256.min(limit.rlim_max);
            assert_eq!(libc::setrlimit(libc::RLIMIT_NOFILE, &limit), 0);
        }
        let raised = raise().expect("limits readable");
        assert_eq!(raised.inherited, 256.min(raised.hard));
        assert!(raised.soft > raised.inherited || raised.hard <= 256);
        assert_eq!(raised.soft, target(raised.inherited, raised.hard));
    }
}
