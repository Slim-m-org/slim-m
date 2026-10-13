// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The invite landing card's banner: set, read signed in, read through a code,
//! and cleared.

use super::PNG;
use crate::world::{Contract, Payload};

pub(super) async fn banner_calls(c: &mut Contract, root: &str, code: &str) {
    c.call(
        "uploadSpaceBanner",
        "POST",
        "/space/banner",
        Some(root),
        Payload::Bytes(PNG.to_vec()),
    )
    .await;
    c.get("getSpaceBanner", "/space/banner", root).await;
    c.call(
        "getInviteBanner",
        "GET",
        &format!("/invites/{code}/banner"),
        None,
        Payload::None,
    )
    .await;
    c.bare("deleteSpaceBanner", "DELETE", "/space/banner", root)
        .await;
}
