// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How many people a machine can carry, as a range. Every constant is a
//! measurement from perf/load/FINDINGS.md or docs/sizing.md; the assumptions
//! around them are written out in docs/capacity-guidance.md.

pub mod host;

use crate::hub::{MAX_CONNECTIONS, RESERVE_BYTES};

/// Resident memory before any connection is open (docs/sizing.md, Memory).
const SERVER_FLOOR_BYTES: u64 = 11_000_000;
/// Memory one open connection adds (docs/sizing.md, re-measured on 0.65.0).
const BYTES_PER_CONNECTION: u64 = 211_000;

/// Deliveries per second per core at the 252k clean fan-out row, which used
/// 2.9 cores (FINDINGS, fanout). The later read-buffer fix made it several
/// times cheaper, so this is deliberately pessimistic.
const DELIVERIES_PER_CORE: f64 = 87_000.0;
/// Only this share of the measured rate is planned on, since the knee is a cliff.
const CPU_SAFETY: f64 = 0.5;
/// Messages a second one connection adds to the one busy channel everyone
/// watches, the worst case for fan-out.
const BUSY_CHANNEL_MESSAGES_PER_SECOND: f64 = 0.1;

/// Last good `http_mix` step by cores (FINDINGS, http_mix); past 8 it is flat.
const HTTP_KNEE: [(f64, f64); 3] = [(2.0, 2000.0), (4.0, 2500.0), (8.0, 3000.0)];
/// Requests a second one active person makes.
const REQUESTS_PER_MEMBER_SECOND: f64 = 0.1;

/// Share of the connection limit planned on at best: one device each.
const BEST_CASE_LOAD: f64 = 0.75;
const BEST_CASE_DEVICES: f64 = 1.0;
/// Share planned on at worst: half the limit, 1.5 devices a person.
const WORST_CASE_LOAD: f64 = 0.5;
const WORST_CASE_DEVICES: f64 = 1.5;

/// LiveKit's floor and per-participant memory (docs/sizing.md, Voice).
const LIVEKIT_FLOOR_BYTES: f64 = 13_000_000.0;
const LIVEKIT_BYTES_PER_PERSON: f64 = 4_700_000.0;
/// Sixty people were comfortable on 512 MB and a hundred hit the cap, so a
/// call is comfortable between these shares of what memory could hold.
const VOICE_COMFORT_LOW: f64 = 0.35;
const VOICE_COMFORT_HIGH: f64 = 0.55;

/// What the estimate is computed from.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Hardware {
    /// Cores this process may use, counting a container's quota.
    pub cores: f64,
    /// RAM this process may use: the cgroup limit when there is one.
    pub memory_bytes: u64,
}

/// The first resource to run out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Binding {
    Connections,
    Memory,
    Processor,
}

impl Binding {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Connections => "connections",
            Self::Memory => "memory",
            Self::Processor => "processor",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Estimate {
    pub connection_limit: u32,
    pub binding: Binding,
    pub members_min: u32,
    pub members_max: u32,
    /// People in one call if LiveKit shares this machine; `None` when voice is off.
    pub voice_min: Option<u32>,
    pub voice_max: Option<u32>,
}

/// Connections the memory can hold once the admission guard's reserve is kept back.
pub fn memory_connections(memory_bytes: u64) -> u64 {
    memory_bytes.saturating_sub(RESERVE_BYTES + SERVER_FLOOR_BYTES) / BYTES_PER_CONNECTION
}

/// Connections the cores can serve when all of them watch one busy channel.
pub fn processor_connections(cores: f64) -> u64 {
    let budget = DELIVERIES_PER_CORE * cores.max(0.0) * CPU_SAFETY;
    (budget / BUSY_CHANNEL_MESSAGES_PER_SECOND).sqrt() as u64
}

/// Requests a second the cores serve before latency queues, interpolated
/// between the measured steps and scaled down linearly below the first.
pub fn http_requests_per_second(cores: f64) -> f64 {
    let cores = cores.max(0.0);
    let (first_cores, first_rate) = HTTP_KNEE[0];
    if cores <= first_cores {
        return first_rate * cores / first_cores;
    }
    for pair in HTTP_KNEE.windows(2) {
        let ((c0, r0), (c1, r1)) = (pair[0], pair[1]);
        if cores <= c1 {
            return r0 + (r1 - r0) * (cores - c0) / (c1 - c0);
        }
    }
    HTTP_KNEE[HTTP_KNEE.len() - 1].1
}

fn request_connections(cores: f64) -> u64 {
    (http_requests_per_second(cores) / REQUESTS_PER_MEMBER_SECOND) as u64
}

fn round_to_ten(value: f64) -> u32 {
    ((value / 10.0).round() * 10.0) as u32
}

/// People that fit in one call when LiveKit gets `bytes`, as a comfortable range.
fn voice_range(bytes: u64, most: u32) -> (u32, u32) {
    let holds = (bytes as f64 - LIVEKIT_FLOOR_BYTES).max(0.0) / LIVEKIT_BYTES_PER_PERSON;
    let clamp = |share: f64| round_to_ten((holds * share).min(f64::from(most)));
    (clamp(VOICE_COMFORT_LOW), clamp(VOICE_COMFORT_HIGH))
}

pub fn estimate(hardware: Hardware, voice_configured: bool) -> Estimate {
    let by_memory = memory_connections(hardware.memory_bytes);
    let by_processor =
        processor_connections(hardware.cores).min(request_connections(hardware.cores));
    let cap = MAX_CONNECTIONS as u64;
    let (limit, binding) = if by_memory.min(by_processor) >= cap {
        (cap, Binding::Connections)
    } else if by_memory <= by_processor {
        (by_memory, Binding::Memory)
    } else {
        (by_processor, Binding::Processor)
    };
    let limit_f = limit as f64;
    let members_max = round_to_ten(limit_f * BEST_CASE_LOAD / BEST_CASE_DEVICES);
    let members_min = round_to_ten(limit_f * WORST_CASE_LOAD / WORST_CASE_DEVICES);
    let (voice_min, voice_max) = if voice_configured {
        let server_needs =
            RESERVE_BYTES + SERVER_FLOOR_BYTES + u64::from(members_max) * BYTES_PER_CONNECTION;
        let (low, high) = voice_range(
            hardware.memory_bytes.saturating_sub(server_needs),
            members_max,
        );
        (Some(low), Some(high))
    } else {
        (None, None)
    };
    Estimate {
        connection_limit: limit as u32,
        binding,
        members_min,
        members_max,
        voice_min,
        voice_max,
    }
}

#[cfg(test)]
mod tests;
