// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /attachments/{id}?original=true`: the file as uploaded, kept beside a
//! compressed copy. Always a download, whatever its type, so an original is
//! never drawn inline.

use axum::http::{HeaderMap, header};
use axum::response::Response;

use super::AppState;
use super::attachments::content_disposition;
use super::error::ApiError;

pub(super) async fn serve(
    state: &AppState,
    attachment_id: &str,
    sha256: &[u8],
    headers: &HeaderMap,
) -> Result<Response, ApiError> {
    let original = state
        .store
        .attachment_original(sha256)
        .await?
        .ok_or(ApiError::NotFound("original not kept"))?;
    let (file, total_len) = state
        .media
        .open_original(attachment_id)
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to open a kept original");
            ApiError::Internal
        })?;
    let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    let mut response = super::attachment_range::serve_ranged(
        file,
        total_len,
        range,
        &original.content_type,
        &original.filename,
    )
    .await?;
    response.headers_mut().insert(
        header::CONTENT_DISPOSITION,
        content_disposition("attachment", &original.filename),
    );
    Ok(response)
}
