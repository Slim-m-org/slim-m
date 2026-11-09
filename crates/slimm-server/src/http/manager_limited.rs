// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The extractor for a `MANAGE_SERVER` route that takes a large body.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use super::AppState;
use super::error::ApiError;
use super::extract::{AuthedLimited, require_manage_server};
use crate::store::SessionContext;

/// A caller who manages the server and has paid the rate limit for class `C`.
///
/// Declared ahead of the body extractor, it settles who the caller is while only
/// the headers have been read. A `MANAGE_SERVER` check inside the handler runs
/// after axum has buffered and parsed the whole body, so anyone signed in could
/// make the server hold megabytes for a request it was always going to refuse.
pub(crate) struct ManagerLimited<const C: u8>(pub(crate) SessionContext);

impl<const C: u8> FromRequestParts<AppState> for ManagerLimited<C> {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let AuthedLimited(ctx) = AuthedLimited::<C>::from_request_parts(parts, state).await?;
        require_manage_server(state, ctx.user_id).await?;
        Ok(ManagerLimited(ctx))
    }
}
