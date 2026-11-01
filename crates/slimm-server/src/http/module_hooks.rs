// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hooks that let a module stand in front of an action (decision 0100): the
//! interceptor chain on a message before it is stored, and the deny-only
//! permission check. A module never grants anything here; it can only reject,
//! annotate or rewrite a message, or turn an allowed action into a denied one.
//!
//! Every path that stores a member's text calls [`intercept`] first; the gate
//! test `module_hooks_paths` fails when a new one does not. With no hook
//! installed the cost is one atomic load, see [`Registry`].

mod chain;
mod module_hooks_admin;
mod permission;
mod registry;
mod runner;

pub(crate) use chain::{Draft, HookPoint, intercept};
pub(super) use module_hooks_admin::routes;
pub(crate) use permission::{Action, check_permission};
pub(crate) use registry::Registry;

/// Longest one hook may run, whatever its manifest asks for.
pub(crate) const HOOK_WALL: std::time::Duration = std::time::Duration::from_millis(100);
/// Most fuel one hook may burn, whatever its manifest asks for.
pub(crate) const HOOK_FUEL: u64 = 10_000_000;
/// The whole chain's cap for one message or one permission check.
pub(crate) const CHAIN_CAP: std::time::Duration = std::time::Duration::from_millis(250);
/// Longest reject reason or failure text shown to a sender.
const MAX_REASON_CHARS: usize = 200;

fn short(text: &str) -> String {
    text.chars().take(MAX_REASON_CHARS).collect()
}
