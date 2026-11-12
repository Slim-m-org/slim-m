// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared, persistent media-tile placement: decision 0010's reversal.
//!
//! The owner's own test was explicit - move a tile, leave, come back
//! tomorrow, and it is still where it was left. `persists_across_a_restart`
//! is that test, driven against a fresh `Store` reconnected to the same
//! database file rather than the same process's in-memory state, so it
//! cannot pass by accident on a cache neither restart nor a real deployment
//! would have.
//!
//! Split across sibling modules, the `canvas_ops` shape, once the
//! single-file version crossed the 500-line hard limit: `write` covers
//! placement, authorization, validation and persistence; `lock` is the
//! shared lock invariant on its own.

mod fixtures;
mod lock;
mod write;
