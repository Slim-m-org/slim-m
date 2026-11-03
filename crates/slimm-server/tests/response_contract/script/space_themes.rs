// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space theme store: publish with a picture, list, fetch the picture,
//! make it the default, remove it.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};

use super::{PNG, text};
use crate::world::{Contract, Payload};

pub(super) fn theme_file(name: &str) -> Value {
    json!({
        "format": "slimm-theme", "version": 1, "name": name, "author": "me",
        "base": "dark", "brightness": "dark",
        "tokens": {
            "surfaceSunken": "#0B0D10", "surfaceBase": "#12151A", "surfaceRaised": "#1C2027",
            "borderSubtle": "#2A2F38", "borderStrong": "#7C8696",
            "textPrimary": "#EEF1F5", "textSecondary": "#A9B2BF", "textDisabled": "#5E6672",
            "accent": "#7FB2FF", "accentFill": "#7FB2FF", "accentOn": "#06101F",
            "accentSoft": "#1B2A44", "accentRing": "#407FB2FF", "focusRing": "#7FB2FF",
            "dangerText": "#F0958A", "dangerBorder": "#D0675B",
            "warnText": "#E0B050", "warnSoft": "#1AE0B050", "stripe": "#12A9B2BF"
        }
    })
}

pub(super) async fn space_theme_calls(c: &mut Contract, root: &str) {
    let mut file = theme_file("Dusk");
    file["backdrop"] = json!({
        "effect": "halloweenWebs",
        "picture": {"data": BASE64.encode(PNG), "dim": 0.5, "vignette": true, "blur": 0.0},
    });
    let created = c
        .json("publishSpaceTheme", "POST", "/space/themes", root, file)
        .await;
    let id = text(&created, "id");
    c.get("listSpaceThemes", "/space/themes", root).await;
    c.call(
        "fetchSpaceThemePicture",
        "GET",
        &format!("/space/themes/{id}/picture"),
        Some(root),
        Payload::None,
    )
    .await;
    c.call(
        "setSpaceDefaultTheme",
        "PUT",
        "/space/default-theme",
        Some(root),
        Payload::Json(json!({ "theme_id": id })),
    )
    .await;
    c.call(
        "deleteSpaceTheme",
        "DELETE",
        &format!("/space/themes/{id}"),
        Some(root),
        Payload::None,
    )
    .await;
}
