// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /attachments/{id}?w=N`: a bounded-size preview of a still image, or the
//! first frame of a gif, so an inline tile does not download the original.
//! Anything that cannot or need not shrink falls through to the stored
//! original, which is always a correct answer to the same request.

use axum::http::HeaderMap;
use axum::response::Response;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::media::preview::{Preview, Variant, bucket_for};
use crate::media::{Media, sniff_content_type};
use crate::store::AttachmentSummary;

/// What a preview request asks for.
pub(super) struct Request {
    pub width: u32,
    /// Also answer an animated WebP or PNG with its first frame, which a gif always gets.
    pub still: bool,
}

/// The derived response for `width`, or `None` when the original should be served.
pub(super) async fn serve(
    media: &Media,
    attachment_id: &str,
    meta: &AttachmentSummary,
    request: Request,
    headers: &HeaderMap,
) -> Option<Response> {
    let original = media.attachment_file(attachment_id);
    let variant = match (meta.content_type.as_str(), request.still) {
        ("image/gif", _) => Variant::Still,
        ("image/jpeg", _) => Variant::Preview,
        ("image/png" | "image/webp", true) => media.previews().variant_for(&original).await,
        ("image/png" | "image/webp", false) => Variant::Preview,
        _ => return None,
    };
    let resolved = media
        .previews()
        .resolve(attachment_id, &original, bucket_for(request.width), variant)
        .await;
    let path = match resolved {
        Ok(Preview::Derived(path)) => path,
        Ok(Preview::Original) => return None,
        Err(err) => {
            tracing::warn!(error = %err, attachment = %attachment_id, "could not derive an attachment preview");
            return None;
        }
    };
    let mut file = tokio::fs::File::open(&path).await.ok()?;
    let total_len = file.metadata().await.ok()?.len();
    let mut prefix = [0u8; 16];
    let read = file.read(&mut prefix).await.ok()?;
    file.seek(std::io::SeekFrom::Start(0)).await.ok()?;
    let content_type = sniff_content_type(&prefix[..read])?;
    let range = headers
        .get(axum::http::header::RANGE)
        .and_then(|v| v.to_str().ok());
    super::attachment_range::serve_ranged(
        file,
        total_len,
        range,
        content_type,
        &preview_filename(&meta.filename, content_type),
    )
    .await
    .ok()
}

/// The original's name with the extension of the type the preview is in.
fn preview_filename(filename: &str, content_type: &str) -> String {
    let stem = filename.rsplit_once('.').map_or(filename, |(stem, _)| stem);
    let extension = if content_type == "image/webp" {
        "webp"
    } else {
        "jpg"
    };
    format!("{stem}.{extension}")
}

#[cfg(test)]
mod tests {
    use super::preview_filename;

    #[test]
    fn the_extension_follows_the_preview_type() {
        assert_eq!(preview_filename("holiday.PNG", "image/jpeg"), "holiday.jpg");
        assert_eq!(preview_filename("noext", "image/webp"), "noext.webp");
    }
}
