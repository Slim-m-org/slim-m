// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The claim shapes signed into a LiveKit join/admin token, and the small
//! time/URL helpers `VoiceService` shares between minting and verifying.
//! Split out of `mod.rs` to stay under the file-size budget; `sign` itself
//! lives in `room_admin.rs`, next to the room-service calls.

use hmac::{Hmac, Mac};
use serde::Serialize;
use sha2::Sha256;

use super::VoiceService;
use crate::ids::{ChannelId, DeviceId};

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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) attributes: Option<std::collections::BTreeMap<&'a str, &'a str>>,
}

#[derive(Serialize)]
pub(super) struct VideoGrant {
    pub(super) room: String,
    #[serde(rename = "roomJoin")]
    pub(super) room_join: bool,
    #[serde(rename = "roomAdmin")]
    pub(super) room_admin: bool,
    /// LiveKit demands this for `DeleteRoom` and nothing else here; it stays off the wire unless set.
    #[serde(rename = "roomCreate", skip_serializing_if = "is_false")]
    pub(super) room_create: bool,
    #[serde(rename = "canSubscribe")]
    pub(super) can_subscribe: bool,
    #[serde(rename = "canPublish")]
    pub(super) can_publish: bool,
    #[serde(rename = "canPublishData")]
    pub(super) can_publish_data: bool,
    #[serde(rename = "canUpdateOwnMetadata")]
    pub(super) can_update_own_metadata: bool,
    /// Keeps the participant out of every other participant's list; only the listener sets it.
    #[serde(skip_serializing_if = "is_false")]
    pub(super) hidden: bool,
}

/// Which running copy of a client a join or a roster read comes from: the session's device,
/// and the tab a browser keeps for itself, since every tab of one profile shares one session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceDevice {
    pub device_id: DeviceId,
    pub tab: Option<String>,
}

impl From<DeviceId> for VoiceDevice {
    fn from(device_id: DeviceId) -> Self {
        Self {
            device_id,
            tab: None,
        }
    }
}

/// A keyed hash of the channel and device: the same for one device in one channel, unrelated
/// across channels, and no use to anyone without the SFU secret.
pub(super) fn device_tag(secret: &str, channel_id: ChannelId, device: &VoiceDevice) -> String {
    let mut mac =
        <Hmac<Sha256>>::new_from_slice(secret.as_bytes()).expect("HMAC takes a key of any length");
    mac.update(b"slimm-voice-device-v1");
    mac.update(channel_id.0.as_bytes());
    mac.update(device.device_id.0.as_bytes());
    // After the fixed-length device id, so a tab can never collide with a device of its own.
    if let Some(tab) = &device.tab {
        mac.update(b"tab");
        mac.update(tab.as_bytes());
    }
    crate::media::to_hex(&mac.finalize().into_bytes()[..16])
}

/// The participant attribute carrying the [`VoiceService::holder_tag`] of the device whose session minted the token.
pub const HOLDER_ATTRIBUTE: &str = "slimm.holder";

impl VoiceService {
    /// What a token minted on `device_id`'s session carries in `channel_id`, so a join can be traced
    /// back to whether that device is still signed in. None when voice is off.
    pub fn holder_tag(&self, channel_id: ChannelId, device_id: DeviceId) -> Option<String> {
        let enabled = self.inner.as_ref()?;
        Some(holder_tag(&enabled.api_secret, channel_id, device_id))
    }
}

/// A keyed hash of the channel and the device alone, so the server can tell which device's
/// credential a participant joined with whatever tab it came from.
pub(super) fn holder_tag(secret: &str, channel_id: ChannelId, device_id: DeviceId) -> String {
    let mut mac =
        <Hmac<Sha256>>::new_from_slice(secret.as_bytes()).expect("HMAC takes a key of any length");
    mac.update(b"slimm-voice-holder-v1");
    mac.update(channel_id.0.as_bytes());
    mac.update(device_id.0.as_bytes());
    crate::media::to_hex(&mac.finalize().into_bytes()[..16])
}

fn is_false(value: &bool) -> bool {
    !*value
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
