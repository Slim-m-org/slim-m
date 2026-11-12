// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Finishing a Steam link from a handoff the harness seeds itself, then the
//! sharing switch and the unlink.
//!
//! The callback needs a configured Steam key and Steam's OpenID check, which
//! this fixture has neither of, so the pending link is seeded straight into
//! the store, the same way the Discord calls do it.

use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::store::PendingLink;

use crate::response_contract::world::Contract;

pub(super) async fn steam_link_calls(c: &mut Contract, token: &str, user_id: &str) {
    let pending = PendingLink {
        user_id: UserId(user_id.parse().unwrap()),
        external_id: "76561197960435530".to_owned(),
        username: "bob_steam".to_owned(),
        display_name: Some("Bob S".to_owned()),
        avatar_hash: None,
    };
    let code = c
        .state
        .store
        .create_link_handoff("steam", &pending, i64::MAX / 2)
        .await
        .unwrap();
    c.json(
        "completeSteamLink",
        "POST",
        "/me/links/steam/complete",
        token,
        json!({ "code": code }),
    )
    .await;
    c.json(
        "setSteamSharing",
        "PUT",
        "/me/links/steam/sharing",
        token,
        json!({ "enabled": true }),
    )
    .await;
    c.bare("unlinkSteam", "DELETE", "/me/links/steam", token)
        .await;
}
