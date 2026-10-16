// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end push tests: registration over HTTP, triggering from the message
//! send path against a real (mock) relay, lifecycle gating, debounce, a dead
//! token clearing the registration, a disabled sender being a true no-op, and
//! the envelope actually being content-free.
//!
//! The mock relay is a real HTTP server on an ephemeral loopback port, so the
//! sender under test exercises its real HTTP client end to end; only APNs/FCM
//! themselves are out of reach here, which is exactly what the relay exists to
//! abstract away.
//!
//! Split across sibling modules, the `canvas_ops` shape, once the single-file
//! version crossed the file-budget hard limit: `harness` is the store, router,
//! and mock relay every test shares, `delivery` is the tests themselves.

mod alerts;
mod call_signals;
mod delivery;
mod harness;
mod missed_call;
mod reply_ping;
#[path = "../support/mod.rs"]
mod support;
