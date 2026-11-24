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
    display_name: &str,
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
    let filename = original_filename(display_name, &original.filename);
    let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    let mut response = super::attachment_range::serve_ranged(
        file,
        total_len,
        range,
        &original.content_type,
        &filename,
    )
    .await?;
    response.headers_mut().insert(
        header::CONTENT_DISPOSITION,
        content_disposition("attachment", &filename),
    );
    Ok(response)
}

/// The caller's own name for the bytes, with the kept original's extension.
fn original_filename(display_name: &str, kept: &str) -> String {
    let stem = display_name
        .rsplit_once('.')
        .map_or(display_name, |(stem, _)| stem);
    match kept.rsplit_once('.') {
        Some((_, extension)) => format!("{stem}.{extension}"),
        None => stem.to_owned(),
    }
}
