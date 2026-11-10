// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Finishing a Discord link, from a handoff the harness holds itself.
//!
//! The callback needs a configured Discord application, which this fixture's
//! router has none of, so the pending link it would have parked is seeded
//! straight into the store; completing it needs no Discord call because it
//! carries no picture.

use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::store::PendingLink;

use crate::world::Contract;

pub(super) async fn discord_link_calls(c: &mut Contract, token: &str, user_id: &str) {
    let pending = PendingLink {
        user_id: UserId(user_id.parse().unwrap()),
        external_id: "80351110224678912".to_owned(),
        username: "bob_d".to_owned(),
        display_name: Some("Bob D".to_owned()),
        avatar_hash: None,
    };
    let expires_at = i64::MAX / 2;
    let code = c
        .state
        .store
        .create_link_handoff("discord", &pending, expires_at)
        .await
        .unwrap();
    c.json(
        "completeDiscordLink",
        "POST",
        "/me/links/discord/complete",
        token,
        json!({ "code": code }),
    )
    .await;
}
