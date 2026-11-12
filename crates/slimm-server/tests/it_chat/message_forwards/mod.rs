// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Forwarding: the origin is resolved by the server, snapshotted at send
//! time, and refused outright for anything the sender cannot legitimately
//! pass on.
//!
//! Split by concern once the single file crossed the line budget:
//! [`core`] is what one forward carries and refuses, [`chains`] is what
//! happens when the thing being forwarded is itself a forward - a case
//! with its own flattening rule and its own access rule. [`fixtures`] is
//! the harness they share.

mod chains;
mod core;
mod deletion;
mod deletion_files;
mod fixtures;
