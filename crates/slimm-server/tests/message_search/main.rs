// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Full-text message search: matching, permission scoping, deleted-message
//! exclusion, malformed FTS5 syntax answering 400 rather than 500, and the
//! Slack-style operator layer (`from:`, `in:`, `has:`, `before:`/`after:`)
//! `http::search` parses those into.
//!
//! Split by which part of the surface a test pins: [`basic`] is the plain
//! `q`-only search this route always had, and the operator layer splits into
//! [`operators_identity`] (`from:`/`in:`, both of which resolve a caller-
//! supplied name and so both carry an oracle-safety obligation) and
//! [`operators_content`] (`has:`/`before:`/`after:`, which read a message's
//! own bytes rather than resolving anything). [`cross_channel`] is the
//! deployment-wide `GET /search/messages` scope instead of the per-channel
//! route the rest of this suite pins. [`fixtures`] is the temp database,
//! router and request builders they all share.

mod basic;
mod cross_channel;
mod cross_channel_paging;
mod fixtures;
mod fts_order;
mod operators_content;
mod operators_identity;

#[path = "../support/mod.rs"]
mod support;
