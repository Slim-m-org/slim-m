// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The claim shapes signed into a LiveKit join/admin token, and the small
//! time/URL helpers `VoiceService` shares between minting and verifying.
//! Split out of `mod.rs` to stay under the file-size budget; `sign` itself
//! lives in `room_admin.rs`, next to the room-service calls.

use serde::Serialize;

/// The LiveKit JWT claim set. Field names are LiveKit's, not ours.
#[derive(Serialize)]
pub(super) struct Claims<'a> {
    pub(super) iss: &'a str,
    pub(super) sub: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) name: Option<&'a str>,
    pub(super) nbf: u64,
    pub(super) exp: u64,
    pub(super) video: VideoGrant,
}

#[derive(Serialize)]
pub(super) struct VideoGrant {
    pub(super) room: String,
    #[serde(rename = "roomJoin")]
    pub(super) room_join: bool,
    #[serde(rename = "roomAdmin")]
    pub(super) room_admin: bool,
    #[serde(rename = "canSubscribe")]
    pub(super) can_subscribe: bool,
    #[serde(rename = "canPublish")]
    pub(super) can_publish: bool,
    #[serde(rename = "canPublishData")]
    pub(super) can_publish_data: bool,
    #[serde(rename = "canUpdateOwnMetadata")]
    pub(super) can_update_own_metadata: bool,
}

pub(super) fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The room service address for a client-facing LiveKit URL.
///
/// LiveKit serves signaling and the room service on the same host, so this is
/// a scheme swap rather than a second setting an operator could get wrong.
pub(super) fn http_url_for(url: &str) -> anyhow::Result<String> {
    let trimmed = url.trim_end_matches('/');
    let swapped = match trimmed.split_once("://") {
        Some(("wss", rest)) => format!("https://{rest}"),
        Some(("ws", rest)) => format!("http://{rest}"),
        Some(("https", _)) | Some(("http", _)) => trimmed.to_owned(),
        _ => anyhow::bail!(
            "LiveKit address ({url}) must start with wss://, ws://, https:// or http://"
        ),
    };
    Ok(swapped)
}
