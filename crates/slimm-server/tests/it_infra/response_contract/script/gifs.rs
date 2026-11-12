// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The GIF proxy's four documented calls, in the order they depend on each
//! other: a search mints the opaque token every later call is keyed on, the
//! preview fetches through it, and select turns it into a real attachment.
//!
//! Trending takes no token and could run anywhere, but sits here so the whole
//! provider surface is validated in one place rather than split across this
//! pass by whether a call happens to need state.
//!
//! Every one of these reaches a real 2xx because the pass runs against a fake
//! local provider rather than Tenor or Klipy; see `world.rs`.

use serde_json::json;

use super::text;
use crate::response_contract::world::Contract;

pub(super) async fn gif_calls(c: &mut Contract, root: &str) {
    let search = c
        .bare("searchGifs", "GET", "/gifs/search?q=cat", root)
        .await;
    let id = text(&search["results"][0], "id");
    c.bare("getGifPreview", "GET", &format!("/gifs/preview/{id}"), root)
        .await;
    c.json(
        "selectGif",
        "POST",
        "/gifs/select",
        root,
        json!({ "id": id }),
    )
    .await;
    c.bare("getTrendingGifs", "GET", "/gifs/trending", root)
        .await;
    favorite_calls(c, root, &id).await;
}

/// A favorite is made from a live search token, so it runs while one is in hand.
async fn favorite_calls(c: &mut Contract, root: &str, gif_id: &str) {
    let fav = uuid::Uuid::now_v7().to_string();
    c.json(
        "addFavorite",
        "POST",
        "/favorites",
        root,
        json!({ "id": fav, "kind": "gif", "gif_id": gif_id }),
    )
    .await;
    c.get("listFavorites", "/favorites", root).await;
    c.bare(
        "getFavoritePreview",
        "GET",
        &format!("/favorites/{fav}/preview"),
        root,
    )
    .await;
    c.json(
        "selectFavorite",
        "POST",
        &format!("/favorites/{fav}/select"),
        root,
        json!({}),
    )
    .await;
    c.json(
        "reorderFavorites",
        "PUT",
        "/favorites/order",
        root,
        json!({ "ids": [fav] }),
    )
    .await;
    c.bare(
        "removeFavorite",
        "DELETE",
        &format!("/favorites/{fav}"),
        root,
    )
    .await;
}
