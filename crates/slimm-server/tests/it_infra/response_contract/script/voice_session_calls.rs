// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A caller's own call in a voice channel: the token, the heartbeat, a mute report and the hangup.

use serde_json::json;
use slimm_server::ids::ChannelId;

use crate::response_contract::world::Contract;

pub(super) async fn voice_session_calls(c: &mut Contract, root: &str, channel: ChannelId) {
    c.bare(
        "mintVoiceToken",
        "POST",
        &format!("/channels/{channel}/voice/token"),
        root,
    )
    .await;
    c.bare(
        "sendVoiceHeartbeat",
        "POST",
        &format!("/channels/{channel}/voice/heartbeat"),
        root,
    )
    .await;
    c.json(
        "setVoiceMuted",
        "PUT",
        &format!("/channels/{channel}/voice/muted"),
        root,
        json!({ "muted": true }),
    )
    .await;
    c.bare(
        "forgetVoiceHeartbeat",
        "DELETE",
        &format!("/channels/{channel}/voice/heartbeat"),
        root,
    )
    .await;
}
