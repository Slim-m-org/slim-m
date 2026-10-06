// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `ringDmCall`/`declineDmCallRing` calls for `content.rs`'s own DM channel,
//! a sibling module rather than folded into `content.rs` (already near the
//! line budget) or `script.rs` itself.
//!
//! Both routes answer without ever reaching a real SFU (starting a ring only
//! records in-memory state and publishes; declining evicts a participant only
//! if one was actually joined, which nothing here does), so - unlike
//! `listVoiceRoster` and `kickVoiceParticipant` in `main.rs`'s own
//! `UNCOVERED` - there is no reason either belongs on that list.

use crate::world::Contract;

/// Root rings bob, then bob declines it - covering both routes' real
/// response shapes in the one exchange a DM call actually needs.
pub(super) async fn dm_call_ring_calls(
    c: &mut Contract,
    root: &str,
    bob_token: &str,
    dm_channel: &str,
) {
    c.bare(
        "ringDmCall",
        "POST",
        &format!("/channels/{dm_channel}/voice/ring"),
        root,
    )
    .await;
    c.bare(
        "listIncomingDmCallRings",
        "GET",
        "/voice/rings/incoming",
        bob_token,
    )
    .await;
    c.bare(
        "declineDmCallRing",
        "POST",
        &format!("/channels/{dm_channel}/voice/ring/decline"),
        bob_token,
    )
    .await;
}
