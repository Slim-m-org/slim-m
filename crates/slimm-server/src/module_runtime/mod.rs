// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The module host: runs an installed module's wasm artifact under strict
//! resource limits, per docs/decisions/0021-modules-and-the-dock.md's Phase
//! 3. This is the one place in slim that executes module code; everything
//! above it (`http::module_commands`) only decides *whether* a call may
//! reach here, never what a module does once it has.
//!
//! # Module ABI v1
//!
//! A module is a wasm binary that exports exactly two functions and one
//! memory, and imports nothing at all - see [`ModuleHost::run`] for why a
//! single import of any kind is refused outright rather than sandboxed.
//!
//! - `memory` (exported linear memory).
//! - `alloc(len: i32) -> i32`: reserves `len` bytes inside the module's own
//!   memory and returns a pointer to them. Called once by the host, before
//!   `run`, to get somewhere to write the request.
//! - `run(in_ptr: i32, in_len: i32) -> i64`: given the request the host just
//!   wrote at `in_ptr`/`in_len`, returns a packed `(out_ptr << 32) | out_len`
//!   pointing at the response, written wherever the module likes (its own
//!   static data, a second `alloc`, or the input region reused in place).
//!
//! The host writes a UTF-8 JSON request into the memory `alloc` returned,
//! calls `run`, and reads `out_len` bytes at `out_ptr` back as a UTF-8 JSON
//! response. What that JSON looks like is a contract between
//! `http::module_commands` and the module, not this host: see that module's
//! own doc for the `{command, input}` / `{ok, output}` / `{ok: false,
//! error}` shapes. [`ModuleHost::run`] itself only moves bytes; it has no
//! opinion about what is inside them.
//!
//! No imports means a module can only compute: it cannot touch the network,
//! the filesystem, or anything else in the host process. That is the entire
//! v1 security model, and it is why every other capability a module might
//! eventually want (posting a message, reading a key-value store) has to
//! come later as an explicit, mediated host function rather than ambient
//! access - see decision 0021's "no ambient authority" principle.
//!
//! # The mediated-capability surface (decision 0023)
//!
//! [`ModuleHost::run_with_capabilities`] is the seam for that "later": with a
//! [`CapabilitySurface`] enabled, a module may import the single gated
//! `slim.host_call` function (and nothing else), whose requests the surface
//! gates and answers: the gate ([`capabilities`]), [`kv`]'s `kv.store` and
//! [`post`]'s `message.post`. A run is enabled only for a module an admin
//! approved a host capability for; every other run passes
//! [`CapabilitySurface::Disabled`] and behaves exactly as the import-free model
//! above. See [`capabilities`] for the gate and the fail-closed guarantees.

mod capabilities;
mod compiled;
mod host;
mod kv;
mod limits;
mod net;
mod post;
mod sliced;

pub use capabilities::CapabilitySurface;
pub use host::{ModuleHost, RunError};
pub use kv::{InMemoryKv, KvBackend, KvError, MAX_ENTRIES, MAX_TOTAL_BYTES};
pub use limits::{MAX_FUEL, MAX_MEMORY_MB, MAX_WALL_MS, RunLimits};
pub use net::{
    FetchRefused, FetchRequest, FetchResponse, HttpFetcher, MAX_RESPONSE_BODY_BYTES, host_allowed,
};
pub use post::{MessagePoster, PostRefused};

#[cfg(test)]
mod tests;

#[cfg(test)]
mod tests_limits;
