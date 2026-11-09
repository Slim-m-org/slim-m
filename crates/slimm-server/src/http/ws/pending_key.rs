// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The address an unauthenticated socket is counted under.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use crate::http::AppState;
use crate::http::extract::limit_key;

/// The address key an unauthenticated socket is counted under, from the same trusted-hops logic as rate limits.
pub(super) struct PendingKey(pub(super) String);

impl FromRequestParts<AppState> for PendingKey {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        Ok(Self(limit_key(parts, None, state.limiter.trusted_hops())))
    }
}
