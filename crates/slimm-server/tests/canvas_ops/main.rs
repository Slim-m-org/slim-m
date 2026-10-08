// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas op stream's catch-up feed: `place` writes one op per placement,
//! the feed pages them densely, and `reset` fires on all three triggers.
//!
//! Split across sibling modules, the `response_contract` shape, once the
//! single-file version crossed the 500-line hard limit: `http_gate` is the
//! route wired end to end, `feed` is everything below it.

mod convergence;
mod feed;
mod feed_budget;
mod fixtures;
mod http_gate;
mod index_plan;
mod lock;
mod r#move;
mod reorder;
mod reorder_bounds;
mod restart_clock;
mod restore;
mod restore_permission;
#[path = "../support/mod.rs"]
mod support;
mod write;
