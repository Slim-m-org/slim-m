// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resource limits [`super::ModuleHost::run`] enforces, and the defaults a
//! manifest that leaves one unset falls back to.

use std::time::Duration;

use wasmi::{StoreLimits, StoreLimitsBuilder};

use crate::store::ModuleRuntimeLimits;

/// Applied when a manifest's `runtime.limits` leaves memory unset: 16 MiB is
/// comfortably inside a self-host's memory budget even with several modules
/// installed, and far above what a pure-compute module needs per call.
const DEFAULT_MEMORY_MB: u64 = 16;
/// Applied when a manifest leaves the wall-clock cap unset. A command is a
/// synchronous request-response call, not a background job, so a second is
/// already generous for the caller waiting on it.
const DEFAULT_WALL_MS: u64 = 1_000;
/// Applied when a manifest leaves fuel unset. wasmi charges roughly one unit
/// of fuel per executed instruction, so this bounds a run to tens of millions
/// of instructions - enough for real work, far short of a runaway loop
/// running forever.
const DEFAULT_FUEL: u64 = 50_000_000;

/// The most memory a manifest may ask for. A manifest's `runtime.limits` is
/// the module's declared ceiling, but the host is the one paying for it, so
/// each limit also has a host-side maximum a manifest cannot exceed - without
/// one, a manifest claiming gigabytes or hours would be honoured verbatim.
/// 256 MiB is far above any pure-compute module's needs while still small
/// against a self-host's total memory.
pub const MAX_MEMORY_MB: u64 = 256;
/// The longest wall-clock cap a manifest may declare. A command is a
/// request-response call the caller waits on, so ten seconds is already long.
pub const MAX_WALL_MS: u64 = 10_000;
/// The largest fuel budget a manifest may declare, forty times the default:
/// fuel is the other bound on a runaway run, and it must stay finite.
pub const MAX_FUEL: u64 = 2_000_000_000;

/// The largest response a module may return. The output is copied out of the
/// guest, parsed and sent whole to the caller, so it is bounded on its own
/// rather than by the (up to 256 MiB) memory ceiling.
pub const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
/// Bytes of the memory ceiling one declared table element is charged, so a
/// table is paid for out of the same budget as linear memory (16 MiB allows
/// one million elements) instead of being a free allocation.
const TABLE_ELEMENT_BYTES: usize = 16;

/// The store limiter for one run: linear memory, plus tables, memories and
/// instances, all of which wasmi allocates at instantiation before any fuel is
/// charged. A v1 module has one memory and one table and is one instance.
pub fn store_limits(memory_bytes: usize) -> StoreLimits {
    StoreLimitsBuilder::new()
        .memory_size(memory_bytes)
        .table_elements(memory_bytes / TABLE_ELEMENT_BYTES)
        .memories(1)
        .tables(1)
        .instances(1)
        .build()
}

/// The concrete caps one `run` call is held to, resolved from a manifest's
/// (possibly partial) `runtime.limits` against the defaults above.
#[derive(Debug, Clone, Copy)]
pub struct RunLimits {
    pub memory_bytes: usize,
    pub fuel: u64,
    pub wall: Duration,
}

/// The least wall clock a module that can call `net.fetch` runs under: one
/// request may take [`MAX_FETCH_MS`], so the run needs that plus time to answer.
pub const NET_FETCH_WALL_FLOOR_MS: u64 = MAX_FETCH_MS + 1_000;
/// The longest one `net.fetch` request is given.
pub const MAX_FETCH_MS: u64 = 5_000;

impl RunLimits {
    /// Raises the wall clock of a module that can fetch, so a slow upstream is
    /// reported to the module instead of timing the whole run out.
    pub fn for_fetching(mut self) -> Self {
        let floor = Duration::from_millis(NET_FETCH_WALL_FLOOR_MS);
        self.wall = self.wall.max(floor);
        self
    }
}

impl From<&ModuleRuntimeLimits> for RunLimits {
    fn from(limits: &ModuleRuntimeLimits) -> Self {
        let memory_mb = limits.memory_mb.unwrap_or(DEFAULT_MEMORY_MB);
        Self {
            memory_bytes: (memory_mb.saturating_mul(1024 * 1024)) as usize,
            fuel: limits.fuel.unwrap_or(DEFAULT_FUEL),
            wall: Duration::from_millis(limits.wall_ms.unwrap_or(DEFAULT_WALL_MS)),
        }
    }
}
