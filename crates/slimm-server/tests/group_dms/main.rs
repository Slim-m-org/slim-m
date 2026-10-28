// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Group DMs (docs/decisions/0095): a DM channel with 3 to 8 participants.
//! The roster is the only grant, blocks gate adding and creating, leaving
//! keeps the channel for everyone else, and a call rings every other person.

mod calls;
mod lifecycle;
mod membership;
mod rig;
#[path = "../support/mod.rs"]
mod support;
