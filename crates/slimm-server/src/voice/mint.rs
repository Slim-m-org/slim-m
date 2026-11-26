// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Minting the three kinds of join token: a member's, the call-audio listener's
//! and a text-to-speech speaker's.

use super::token::{self, Claims, VideoGrant, unix_secs};
use super::{
    DEVICE_ATTRIBUTE, HOLDER_ATTRIBUTE, LISTENER_IDENTITY_PREFIX, RoomToken,
    SPEAKER_IDENTITY_PREFIX, TOKEN_TTL_SECS, VoiceDevice, VoiceError, VoiceService,
    room_for_channel,
};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

impl VoiceService {
    /// Mints a join token for `user_id` in `channel_id`.
    ///
    /// The caller is responsible for having checked that the user may connect;
    /// what this does is turn the permissions it is handed into the matching
    /// SFU grants, so the two cannot drift apart at the call site.
    pub fn mint(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        permissions: Permissions,
        display_name: &str,
        device: impl Into<VoiceDevice>,
    ) -> Result<RoomToken, VoiceError> {
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };

        let room = room_for_channel(channel_id);
        let device = device.into();
        let holder = token::holder_tag(&enabled.api_secret, channel_id, device.device_id);
        let device = token::device_tag(&enabled.api_secret, channel_id, &device);
        let attributes = [(DEVICE_ATTRIBUTE, &*device), (HOLDER_ATTRIBUTE, &*holder)];
        let can_publish = permissions.contains(Permissions::SPEAK);
        let can_publish_data = permissions.contains(Permissions::USE_CANVAS);
        let now = unix_secs();
        let expires = now + TOKEN_TTL_SECS;

        let grants = VideoGrant {
            room: room.clone(),
            room_join: true,
            can_subscribe: true,
            can_publish,
            can_publish_data,
            // The display name is set below; no reason to let a client rewrite it mid-call.
            can_update_own_metadata: false,
            hidden: false,
            room_admin: false,
            room_create: false,
        };

        let token = self.sign(
            enabled,
            Claims {
                iss: &enabled.api_key,
                sub: &user_id.to_string(),
                name: Some(display_name),
                nbf: now,
                exp: expires,
                video: grants,
                attributes: Some(attributes.into()),
            },
        )?;

        self.recent_joins.record(channel_id, crate::store::now_ms());
        Ok(RoomToken {
            url: enabled.url.clone(),
            room,
            token,
            expires_at: (expires as i64) * 1000,
            can_publish,
        })
    }

    /// Mints the call-audio listener's token: room-scoped, hidden, able to
    /// subscribe and nothing else, for `session` (decision 0105). Its identity
    /// never parses as a user id, so the webhook and roster paths skip it.
    pub fn mint_listener(
        &self,
        channel_id: ChannelId,
        session: uuid::Uuid,
        livekit_url: Option<&str>,
    ) -> Result<RoomToken, VoiceError> {
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };
        let room = room_for_channel(channel_id);
        let now = unix_secs();
        let expires = now + TOKEN_TTL_SECS;
        let identity = format!("{LISTENER_IDENTITY_PREFIX}{session}");
        let token = self.sign(
            enabled,
            Claims {
                iss: &enabled.api_key,
                sub: &identity,
                name: None,
                nbf: now,
                exp: expires,
                video: VideoGrant {
                    room: room.clone(),
                    room_join: true,
                    room_admin: false,
                    room_create: false,
                    can_subscribe: true,
                    can_publish: false,
                    can_publish_data: false,
                    can_update_own_metadata: false,
                    hidden: true,
                },
                attributes: None,
            },
        )?;
        Ok(RoomToken {
            url: livekit_url.unwrap_or(&enabled.url).to_owned(),
            room,
            token,
            expires_at: (expires as i64) * 1000,
            can_publish: false,
        })
    }

    /// Mints the token of the short-lived participant that speaks `user_id`'s text
    /// into `channel_id`'s call (decision 0142): visible, publish-only, named
    /// "<name> (TTS)", with an identity that never parses as a user id.
    pub fn mint_speaker(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        display_name: &str,
        livekit_url: Option<&str>,
    ) -> Result<RoomToken, VoiceError> {
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };
        let room = room_for_channel(channel_id);
        let now = unix_secs();
        let expires = now + TOKEN_TTL_SECS;
        let identity = format!("{SPEAKER_IDENTITY_PREFIX}{user_id}");
        let name = format!("{display_name} (TTS)");
        let token = self.sign(
            enabled,
            Claims {
                iss: &enabled.api_key,
                sub: &identity,
                name: Some(&name),
                nbf: now,
                exp: expires,
                video: VideoGrant {
                    room: room.clone(),
                    room_join: true,
                    room_admin: false,
                    room_create: false,
                    can_subscribe: false,
                    can_publish: true,
                    can_publish_data: false,
                    can_update_own_metadata: false,
                    hidden: false,
                },
                attributes: None,
            },
        )?;
        Ok(RoomToken {
            url: livekit_url.unwrap_or(&enabled.url).to_owned(),
            room,
            token,
            expires_at: (expires as i64) * 1000,
            can_publish: true,
        })
    }
}
