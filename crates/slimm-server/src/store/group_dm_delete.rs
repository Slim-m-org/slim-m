// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting a group DM for everyone in it.
//!
//! The channel is soft-deleted exactly as the last person leaving does it, so
//! the retention sweep prunes its messages, attachments and search rows the
//! way it does for any deleted channel. The roster stays: it is what lets a
//! retried delete answer 204 and what scopes the live `channel.deleted` event.

use crate::ids::{ChannelId, UserId};

use super::group_dms::GroupDmError;
use super::{Store, now_ms};

impl Store {
    /// Deletes the group for all of its people. `Ok(false)` means it was already gone.
    ///
    /// Any participant may, a creator being no different from the rest. A caller
    /// who is not on the roster gets [`GroupDmError::NotFound`], whether or not the group exists.
    pub async fn delete_group_dm(
        &self,
        actor: UserId,
        channel_id: ChannelId,
    ) -> Result<bool, GroupDmError> {
        let now = now_ms();
        let deleted = sqlx::query!(
            "UPDATE channels SET deleted_at = ?
             WHERE id = ? AND deleted_at IS NULL
               AND EXISTS (SELECT 1 FROM group_dm_members
                           WHERE channel_id = channels.id AND user_id = ?)",
            now,
            channel_id,
            actor
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        if deleted > 0 {
            return Ok(true);
        }
        if self.is_group_dm_member(actor, channel_id).await? {
            return Ok(false);
        }
        Err(GroupDmError::NotFound)
    }
}
