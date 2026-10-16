// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting several messages as one act, and the four ways that can go wrong
//! quietly.
//!
//! A bulk path that does less than the single one is the failure this file
//! exists for. It cannot be caught by "did the messages disappear" alone, so
//! every case here also checks the thing that is easy to drop and invisible
//! from the transcript: one op per message and no gaps in the sequence, the
//! attachment links released, the audit row written, and nothing at all
//! written when the request is refused.
//!
//! The op-density case is the one worth understanding. Clients apply an op only
//! when its seq is exactly one past their cursor and fall back to a full REST
//! reconcile otherwise, so a batch that allocated one seq for N deletions would
//! be correct in the database and make every connected client resync - the
//! opposite of what a purge is for.
//!
//! Split across sibling modules, the `push_endpoints` shape, once the
//! single-file version crossed the file-budget hard limit: `harness` is the
//! store, router, and request helpers every test shares, `cases` is the tests
//! themselves.

mod audit_subjects;
mod cases;
mod harness;
#[path = "../support/mod.rs"]
mod support;
