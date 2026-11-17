// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The sharer's lists of who stamped pictures on their screen and of one sender's pictures,
//! holding one stamp so the item shapes are checked.
//!
//! The stamp is written through the store: placing one needs a reachable LiveKit room service.

use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::NewScreenStamp;

use super::{PNG, text};
use crate::response_contract::world::{Contract, Payload};

pub(super) async fn screen_stamp_calls(
    c: &mut Contract,
    root: &str,
    admin_id: &str,
    bob_token: &str,
    bob_id: &str,
    channel: &str,
) {
    let uploaded = c
        .call(
            "uploadAttachment",
            "POST",
            "/attachments?filename=stamp.png",
            Some(bob_token),
            Payload::Bytes(PNG.to_vec()),
        )
        .await;
    let sha256 = slimm_server::media::from_hex(&text(&uploaded, "id")).unwrap();
    let stamp = NewScreenStamp {
        id: uuid::Uuid::now_v7(),
        channel_id: ChannelId(channel.parse().unwrap()),
        sender_id: UserId(bob_id.parse().unwrap()),
        target_id: UserId(admin_id.parse().unwrap()),
        sha256: &sha256,
    };
    c.state.store.insert_screen_stamp(&stamp).await.unwrap();
    c.get(
        "listReceivedScreenStamps",
        "/voice/screen-stamps/received",
        root,
    )
    .await;
    c.get(
        "listReceivedScreenStampsFrom",
        &format!("/voice/screen-stamps/received/{bob_id}"),
        root,
    )
    .await;
}
