// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Whether a channel is hidden from `@everyone`, for one channel at a time.

use super::super::Store;
use super::super::permissions::everyone_role_id;
use crate::ids::{ChannelId, RoleId};
use crate::permissions::{Overwrite, Permissions, evaluate};

impl Store {
    /// True when `@everyone` lacks VIEW_CHANNEL in this channel. The same
    /// answer for every reader, and the single-channel form of what
    /// `GET /channels` reports per row.
    pub async fn channel_restricted(&self, channel_id: ChannelId) -> anyhow::Result<bool> {
        let Some(everyone) = everyone_role_id(&self.pool).await? else {
            return Ok(false);
        };
        let base = self
            .role(RoleId(everyone))
            .await?
            .map_or(Permissions::NONE, |role| role.permissions);
        let overwrite = self
            .overwrite_for(channel_id, "role", everyone)
            .await?
            .map(|(allow, deny)| Overwrite { allow, deny });
        Ok(!evaluate(base, &[], overwrite, &[], None).contains(Permissions::VIEW_CHANNEL))
    }
}
