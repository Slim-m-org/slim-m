// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The extractor for a route only a connector's own token may call, and which takes a body.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use super::AppState;
use super::error::ApiError;
use super::extract::AuthedLimited;
use crate::store::SessionContext;

/// A connector's own session that has paid the rate limit for class `C`.
///
/// Declared ahead of the body extractor, it refuses every other caller while only
/// the headers have been read, so a member cannot make the server buffer a
/// megabyte for a request it was always going to turn away.
pub(crate) struct ConnectorLimited<const C: u8>(pub(crate) SessionContext);

impl<const C: u8> FromRequestParts<AppState> for ConnectorLimited<C> {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let AuthedLimited(ctx) = AuthedLimited::<C>::from_request_parts(parts, state).await?;
        if ctx.connector.is_none() {
            return Err(ApiError::ForbiddenBecause(
                "only a connector's own token can answer its runs",
            ));
        }
        Ok(ConnectorLimited(ctx))
    }
}
