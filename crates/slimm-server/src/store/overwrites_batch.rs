// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Applying several channel overwrites in one round trip: the permissions
//! grid needs to save every pending cell change in one request rather than
//! one `PUT .../overwrites/{kind}/{id}` per changed target.
//!
//! Escalation and existence checks stay in `http::overwrites`, the same
//! split `store::permissions::set_role_overwrite`/`set_member_overwrite`
//! already draw with their own callers: this module only persists, inside
//! one transaction so a partial failure never leaves the grid half-saved.

use uuid::Uuid;

use super::Store;
use super::permissions::set_overwrite;
use crate::ids::ChannelId;
use crate::permissions::Permissions;

/// One target's full replacement allow/deny pair.
pub struct OverwriteBatchEntry {
    pub target_type: &'static str,
    pub target_id: Uuid,
    pub allow: Permissions,
    pub deny: Permissions,
}

impl Store {
    /// Applies every entry in `entries` atomically. The caller has already
    /// checked each entry's escalation and existence before calling this -
    /// see `http::overwrites::batch_set` - so a failure here is only ever a
    /// database error, never a refused entry.
    pub async fn set_channel_overwrites_batch(
        &self,
        channel_id: ChannelId,
        entries: &[OverwriteBatchEntry],
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        for entry in entries {
            set_overwrite(
                &mut *tx,
                channel_id,
                entry.target_type,
                entry.target_id,
                entry.allow,
                entry.deny,
            )
            .await?;
        }
        super::category_overwrites::mark_unsynced(&mut *tx, channel_id).await?;
        tx.commit().await?;
        Ok(())
    }
}
