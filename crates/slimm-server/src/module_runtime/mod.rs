// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The module host: the one place slim executes module code, under strict
//! resource limits (decision 0021). A module imports nothing unless an admin
//! approved a host capability (decision 0023); the ABI is in
//! docs/internals.md.

mod capabilities;
mod compiled;
mod gate;
mod host;
mod kv;
mod limits;
mod net;
mod post;
mod sliced;

#[doc(hidden)]
pub use crate::net_guard::treat_loopback_as_lan_for_tests;
pub use capabilities::CapabilitySurface;
pub use gate::RunLane;
pub use host::{ModuleHost, RunError};
pub use kv::{InMemoryKv, KvBackend, KvError, MAX_ENTRIES, MAX_TOTAL_BYTES};
pub use limits::{
    MAX_FETCH_MS, MAX_FUEL, MAX_MEMORY_MB, MAX_WALL_MS, NET_FETCH_WALL_FLOOR_MS, RunLimits,
};
pub use net::{
    FetchRefused, FetchRequest, FetchResponse, HttpFetcher, MAX_RESPONSE_BODY_BYTES, NoSecrets,
    SecretSource, host_allowed, parse_with_secrets,
};
pub use post::{MessagePoster, PostRefused};

#[cfg(test)]
mod tests;

#[cfg(test)]
mod tests_limits;
