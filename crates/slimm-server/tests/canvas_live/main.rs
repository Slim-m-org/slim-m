// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A placed canvas object reaching a live socket, and the two things that gate it.
//! A canvas frame needs both `VIEW_CHANNEL` and `USE_CANVAS`, so the fan-out cache must remember two bits; and a canvas burst must not close a text-only connection sharing the broadcast ring.

mod delivery;
mod fixtures;
mod gating;
mod locks;
mod requests;
#[path = "../support/mod.rs"]
mod support;
