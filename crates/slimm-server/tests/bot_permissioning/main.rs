// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's declared permissions, its managed role, and the guards around
//! both: the escalation check that stops an admin granting a bot bits they
//! do not hold, the outright refusal of ADMINISTRATOR to any bot, and the
//! moderation-audit trail decision 0028 promised for bot lifecycle. See
//! `docs/decisions/0028-bot-accounts.md`.
//!
//! Split across files (`harness`, `grants`, `lifecycle`, `reissue`) rather than
//! one, the same shape `tests/response_contract/` already uses, once the
//! single-file draft passed the 500-line hard limit.

#[path = "../support/mod.rs"]
mod support;

mod grants;
mod harness;
mod lifecycle;
mod reissue;
