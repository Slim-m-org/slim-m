// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A placed canvas object reaching a live socket, and the two things that
//! gate it.
//!
//! `USE_CANVAS` is the reason this file exists. Every other channel-scoped
//! frame is gated on `VIEW_CHANNEL` alone, so the fan-out cache only ever had
//! to remember one bit; a canvas frame needs both, or somebody an overwrite
//! denied the canvas is handed over the socket exactly what
//! `GET /canvas/objects` refuses them. The test below fails if the cache goes
//! back to being a bool.
//!
//! The second is that a canvas burst must stay a canvas burst. The hub is one
//! broadcast channel for the whole deployment, and a lagging subscriber is
//! closed rather than skipped, so a text-only connection sharing that ring
//! with somebody drawing has to survive it.

mod delivery;
mod fixtures;
mod gating;
mod requests;
#[path = "../support/mod.rs"]
mod support;
