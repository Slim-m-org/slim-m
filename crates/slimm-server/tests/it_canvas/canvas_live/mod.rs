// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A placed canvas object reaching a live socket, and the two things that gate it.
//! A canvas frame reaches whoever can see the channel, a spectator without `USE_CANVAS` included; and a canvas burst must not close a text-only connection sharing the broadcast ring.

mod delivery;
mod fixtures;
mod gating;
mod locks;
mod requests;
