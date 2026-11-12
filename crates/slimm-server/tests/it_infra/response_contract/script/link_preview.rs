// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The link-preview surface's two documented calls. Link previews are enabled
//! in `world.rs` against the same fake upstream the GIF pass uses, and its
//! test seam lets the guard reach that loopback server, so `getLinkPreview`
//! unfurls a real page to a 200 and `getLinkPreviewImage` proxies its image -
//! both reaching a genuine 2xx the way every other pass here does.

use super::text;
use crate::response_contract::world::Contract;

pub(super) async fn link_preview_calls(c: &mut Contract, root: &str, upstream: &str) {
    let uri = format!("/link-preview?url={upstream}/page");
    let preview = c.bare("getLinkPreview", "GET", &uri, root).await;
    let token = text(&preview, "image_token");
    c.bare(
        "getLinkPreviewImage",
        "GET",
        &format!("/link-preview/image/{token}"),
        root,
    )
    .await;
}
