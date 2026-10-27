// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Server-side LiveKit room administration: removing and updating participants.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use hmac::{Hmac, Mac};
use sha2::Sha256;

use super::token::{Claims, VideoGrant, unix_secs};
use super::{
    ADMIN_TOKEN_TTL_SECS, DEAFENED_ATTRIBUTE, DEAFENED_ATTRIBUTE_ON, Enabled, VoiceError,
    VoiceService, room_for_channel,
};
use crate::ids::{ChannelId, UserId};

impl VoiceService {
    /// Removes a participant from a channel's room immediately.
    ///
    /// Used when somebody loses the right to be there, which a token they
    /// already hold would otherwise let them keep exercising until it lapses.
    /// Best-effort by design: it is called from paths whose real work has
    /// already committed, so a failure is logged rather than propagated, and
    /// the short token TTL is the backstop.
    pub async fn remove_participant(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
    ) -> Result<(), VoiceError> {
        // Ended on purpose, so a later sweep must not rediscover and re-call it.
        self.heartbeats.forget(user_id, channel_id);
        self.roster_cache.invalidate(channel_id);
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };
        let room = room_for_channel(channel_id);
        // Kicking someone not in the room is the ordinary case, not an error.
        self.room_service_call(
            enabled,
            "RemoveParticipant",
            &room,
            serde_json::json!({ "room": room, "identity": user_id.to_string() }),
        )
        .await?;
        Ok(())
    }

    /// Publishes whether [`user_id`] has deafened themselves, as a participant
    /// attribute everyone in the room reads. Clients may not set their own
    /// attributes (the token withholds `canUpdateOwnMetadata`, which would also
    /// let them rename themselves), so the server sets this one on their behalf.
    pub async fn set_participant_deafened(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        deafened: bool,
    ) -> Result<(), VoiceError> {
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };
        let room = room_for_channel(channel_id);
        // LiveKit drops an attribute set to the empty string.
        let value = if deafened { DEAFENED_ATTRIBUTE_ON } else { "" };
        self.room_service_call(
            enabled,
            "UpdateParticipant",
            &room,
            serde_json::json!({
                "room": room,
                "identity": user_id.to_string(),
                "attributes": { (DEAFENED_ATTRIBUTE): value },
            }),
        )
        .await?;
        Ok(())
    }

    /// One authenticated room-service call, the single place that mints the admin token, posts the
    /// request and reads the status. `Ok(None)` is a 404: the room, or the participant in it, is
    /// already gone, which every caller treats as the state it asked for.
    pub(super) async fn room_service_call(
        &self,
        enabled: &Enabled,
        method: &str,
        room: &str,
        body: serde_json::Value,
    ) -> Result<Option<reqwest::Response>, VoiceError> {
        let admin = self.admin_token(enabled, room)?;
        let response = enabled
            .http
            .post(format!(
                "{}/twirp/livekit.RoomService/{method}",
                enabled.service_url
            ))
            .bearer_auth(admin)
            .json(&body)
            .send()
            .await
            .map_err(|e| VoiceError::Internal(e.into()))?;
        let status = response.status();
        if status == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !status.is_success() {
            return Err(VoiceError::Internal(anyhow::anyhow!(
                "livekit room service refused {method}: {status}"
            )));
        }
        Ok(Some(response))
    }

    /// A room-admin token good for one immediate call, the shape
    /// [`Self::room_service_call`] needs.
    pub(super) fn admin_token(&self, enabled: &Enabled, room: &str) -> Result<String, VoiceError> {
        let now = unix_secs();
        self.sign(
            enabled,
            Claims {
                iss: &enabled.api_key,
                sub: "slim-m-server",
                name: None,
                nbf: now,
                exp: now + ADMIN_TOKEN_TTL_SECS,
                video: VideoGrant {
                    room: room.to_owned(),
                    room_admin: true,
                    room_join: false,
                    can_subscribe: false,
                    can_publish: false,
                    can_publish_data: false,
                    can_update_own_metadata: false,
                },
            },
        )
    }

    /// Signs a claim set as an HS256 JWT, which is the format LiveKit takes.
    ///
    /// The header is a fixed string rather than something built from a struct:
    /// there is exactly one algorithm this ever uses, and writing it out means
    /// nothing can influence it.
    pub(super) fn sign(&self, enabled: &Enabled, claims: Claims<'_>) -> Result<String, VoiceError> {
        const HEADER: &str = r#"{"alg":"HS256","typ":"JWT"}"#;
        let payload = serde_json::to_vec(&claims)
            .map_err(|e| VoiceError::Internal(anyhow::Error::from(e)))?;

        let signing_input = format!(
            "{}.{}",
            BASE64URL.encode(HEADER),
            BASE64URL.encode(&payload)
        );

        let mut mac = <Hmac<Sha256>>::new_from_slice(enabled.api_secret.as_bytes())
            .map_err(|e| VoiceError::Internal(anyhow::anyhow!("livekit secret rejected: {e}")))?;
        mac.update(signing_input.as_bytes());
        let signature = BASE64URL.encode(mac.finalize().into_bytes());

        Ok(format!("{signing_input}.{signature}"))
    }
}
