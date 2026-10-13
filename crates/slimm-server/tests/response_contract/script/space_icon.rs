// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space icon: set, read signed in, read through a code,
//! and cleared.

use super::PNG;
use crate::world::{Contract, Payload};

pub(super) async fn icon_calls(c: &mut Contract, root: &str, code: &str) {
    c.call(
        "uploadSpaceIcon",
        "POST",
        "/space/icon",
        Some(root),
        Payload::Bytes(PNG.to_vec()),
    )
    .await;
    c.get("getSpaceIcon", "/space/icon", root).await;
    c.call(
        "getInviteIcon",
        "GET",
        &format!("/invites/{code}/icon"),
        None,
        Payload::None,
    )
    .await;
    c.bare("deleteSpaceIcon", "DELETE", "/space/icon", root)
        .await;
}
