// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a channel update may ask of the channel's kind: the voice-only settings, and the canvas and call toggles of decision 0139.

use super::super::AppState;
use super::super::error::ApiError;
use super::UpdateChannelRequest;
use super::channel_validation::{
    CANVAS_FLAG_VOICE_ONLY, JOIN_MUTED_VOICE_ONLY, ROOMS_VOICE_ONLY, VOICE_FLAG_CANVAS_ONLY,
};
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::store::{CANVAS_CHANNEL_KIND, Channel, VOICE_CHANNEL_KIND};

/// The parts of an update request that depend on what kind of channel it lands on.
pub(super) struct KindSensitive {
    join_muted_on: bool,
    makes_rooms: bool,
    limits: bool,
    canvas_enabled: Option<bool>,
    voice_enabled: Option<bool>,
    pub(super) discard: bool,
}

impl KindSensitive {
    pub(super) fn of(req: &UpdateChannelRequest, user_limit: Option<i64>) -> Self {
        Self {
            join_muted_on: req.join_muted == Some(true),
            makes_rooms: req.creates_rooms == Some(true),
            limits: user_limit.is_some_and(|limit| limit > 0),
            canvas_enabled: req.canvas_enabled,
            voice_enabled: req.voice_enabled,
            discard: req.discard_canvas == Some(true),
        }
    }

    /// Whether the request carries a canvas or call toggle, which counts as something to update.
    pub(super) fn toggles(&self) -> bool {
        self.canvas_enabled.is_some() || self.voice_enabled.is_some() || self.discard
    }

    pub(super) fn needs_channel(&self) -> bool {
        self.join_muted_on || self.makes_rooms || self.limits || self.toggles()
    }

    /// Refuses a setting the channel's kind has no meaning for; `discard` also needs `MANAGE_CANVAS` there.
    pub(super) async fn check(
        &self,
        state: &AppState,
        user_id: UserId,
        current: &Channel,
    ) -> Result<(), ApiError> {
        let voice = current.kind == VOICE_CHANNEL_KIND;
        if !voice && self.join_muted_on {
            return Err(ApiError::BadRequest(JOIN_MUTED_VOICE_ONLY));
        }
        if (self.makes_rooms || self.limits) && !voice || self.makes_rooms && current.room.is_room()
        {
            return Err(ApiError::BadRequest(ROOMS_VOICE_ONLY));
        }
        if self.canvas_enabled.is_some() && !voice {
            return Err(ApiError::BadRequest(CANVAS_FLAG_VOICE_ONLY));
        }
        if self.voice_enabled.is_some() && current.kind != CANVAS_CHANNEL_KIND {
            return Err(ApiError::BadRequest(VOICE_FLAG_CANVAS_ONLY));
        }
        if self.discard {
            self.check_discard(state, user_id, current).await?;
        }
        Ok(())
    }

    async fn check_discard(
        &self,
        state: &AppState,
        user_id: UserId,
        current: &Channel,
    ) -> Result<(), ApiError> {
        if current.kind != VOICE_CHANNEL_KIND {
            return Err(ApiError::BadRequest("discard_canvas is for voice channels"));
        }
        let permissions = state
            .store
            .permissions_in_channel(user_id, current.id)
            .await?;
        if !permissions.contains(Permissions::MANAGE_CANVAS) {
            return Err(ApiError::Forbidden);
        }
        let open_after = self.canvas_enabled.unwrap_or(current.canvas_enabled);
        if open_after {
            return Err(ApiError::BadRequest("clear an open canvas from the board"));
        }
        Ok(())
    }
}
