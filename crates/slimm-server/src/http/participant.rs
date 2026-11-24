// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The guard for a route that checks no permission bit: a timeout and the join gate are
//! only ever subtracted from bits, so such a route honours neither without it.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use super::AppState;
use super::error::ApiError;
use super::extract::AuthedLimited;
use crate::ids::UserId;
use crate::store::{MemberGate, SessionContext};

/// The reason a pending member is refused, the same one `dms::open` gives.
pub(crate) const ACCEPT_RULES_FIRST: &str = "accept the rules first";

/// A caller past the join gate and not timed out, who has paid the rate limit for class `C`.
pub(crate) struct Participant<const C: u8>(pub(crate) SessionContext);

impl<const C: u8> FromRequestParts<AppState> for Participant<C> {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let AuthedLimited(ctx) = AuthedLimited::<C>::from_request_parts(parts, state).await?;
        require_participant(state, ctx.user_id).await?;
        Ok(Participant(ctx))
    }
}

/// Both holds [`Participant`] applies, for a caller that is not the request's own session.
pub(crate) async fn require_participant(state: &AppState, user_id: UserId) -> Result<(), ApiError> {
    require_admitted(state, user_id).await?;
    require_not_timed_out(state, user_id).await
}

/// Refuses a member who has not yet accepted the rules.
pub(crate) async fn require_admitted(state: &AppState, user_id: UserId) -> Result<(), ApiError> {
    match state.store.member_gate(user_id).await? {
        MemberGate::Member => Ok(()),
        MemberGate::Pending { .. } => Err(ApiError::ForbiddenBecause(ACCEPT_RULES_FIRST)),
    }
}

/// Refuses a member whose timeout is in force, saying when it lifts and why.
pub(crate) async fn require_not_timed_out(
    state: &AppState,
    user_id: UserId,
) -> Result<(), ApiError> {
    match state.store.member_timeout(user_id).await? {
        None => Ok(()),
        Some(timeout) => Err(ApiError::TimedOut {
            until: timeout.until,
            reason: timeout.reason,
        }),
    }
}
