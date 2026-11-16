// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The shared "you cannot reach above your own level" comparison.
//!
//! [`members.rs`](super::members) states the reasoning this exists to carry
//! forward: the comparison reads *granted* permissions, never effective ones,
//! so that a subtraction already in force against the target - a timeout, most
//! notably - cannot itself be what makes them look junior enough to be acted
//! on again. Reading effective permissions here would let a caller time
//! somebody out, watch that very timeout strip a bit the target used to hold,
//! and then qualify to act on them a second time on the strength of a state
//! the first action caused.
//!
//! This module is only the comparison. Every consumer's two permission sets
//! come from a different scope (deployment-wide for member moderation,
//! per-channel for a voice kick, a role's own stored bits for role
//! management), so resolving them is each consumer's job, not this one's; a
//! database read here would fix this module to one of those scopes and be
//! wrong for the others. Whether a self-check applies is a per-consumer
//! decision too: it is correct for member moderation (see
//! [`super::members::authorize`]), wrong for a voice kick (kicking yourself
//! is harmless), and meaningless for role management (a role is not a user).
//!
//! Who ranks above whom by role is [`super::role_ladder`]'s question, asked on top of this one.

use super::error::ApiError;
use crate::permissions::Permissions;

/// Refuses unless `caller_granted` contains every bit `target_granted` holds.
pub(super) fn escalation_guard(
    caller_granted: Permissions,
    target_granted: Permissions,
) -> Result<(), ApiError> {
    if caller_granted.contains(target_granted) {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}
