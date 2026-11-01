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

/// The reason a peer is refused, which the client matches to say so in plain words.
pub(crate) const EQUAL_RANK_REFUSED: &str = "you cannot act on someone of equal rank";

/// [`escalation_guard`] for acts on a person: an equal-rank peer is refused too.
///
/// An administrator is exempt, since their grant contains every bit and no one ranks above them.
pub(super) fn peer_guard(
    caller_granted: Permissions,
    target_granted: Permissions,
) -> Result<(), ApiError> {
    escalation_guard(caller_granted, target_granted)?;
    if caller_granted == target_granted && !caller_granted.contains(Permissions::ADMINISTRATOR) {
        return Err(ApiError::ForbiddenBecause(EQUAL_RANK_REFUSED));
    }
    Ok(())
}

/// The role-position check a voice kick adds on top of the bit comparison:
/// unless the caller is an administrator, their highest role must sit above
/// the target's (decision 0092, owner decision 2026-10-28).
///
/// Bits alone cannot rank people in a call, since a channel overwrite can give
/// every participant KICK_MEMBERS and so make everyone a peer of everyone.
/// No role at all ranks below every role.
pub(super) fn role_rank_guard(
    caller_is_admin: bool,
    caller_position: Option<i64>,
    target_position: Option<i64>,
) -> Result<(), ApiError> {
    if caller_is_admin {
        return Ok(());
    }
    match caller_position.cmp(&target_position) {
        std::cmp::Ordering::Greater => Ok(()),
        std::cmp::Ordering::Equal => Err(ApiError::ForbiddenBecause(EQUAL_RANK_REFUSED)),
        std::cmp::Ordering::Less => Err(ApiError::Forbidden),
    }
}
