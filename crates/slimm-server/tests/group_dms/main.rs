// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Group DMs (docs/decisions/0095): a DM channel with 3 to 10 participants.
//! The roster is the only grant, blocks gate adding and creating, leaving
//! keeps the channel for everyone else, and a call rings every other person.

mod calls;
mod create_errors;
mod lifecycle;
mod live;
mod membership;
mod rig;
#[path = "../support/mod.rs"]
mod support;
