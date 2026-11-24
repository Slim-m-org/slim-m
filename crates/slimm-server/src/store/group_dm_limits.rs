// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How many group DMs one account may belong to at once.

use crate::ids::UserId;

use super::Store;
use super::group_dms::GroupDmError;

/// Most live groups one account may be in; leaving or deleting one frees a place.
pub const GROUP_DM_MAX_PER_ACCOUNT: i64 = 100;

impl Store {
    /// Refuses when `user_id` already sits in [`GROUP_DM_MAX_PER_ACCOUNT`] live groups.
    ///
    /// Runs inside the write transaction that would add the next one, so two racing writes cannot both pass.
    pub(super) async fn refuse_at_group_cap(
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        user_id: UserId,
    ) -> Result<(), GroupDmError> {
        let live = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM group_dm_members g
               JOIN channels c ON c.id = g.channel_id AND c.deleted_at IS NULL
               WHERE g.user_id = ?"#,
            user_id
        )
        .fetch_one(&mut **tx)
        .await?;
        if live >= GROUP_DM_MAX_PER_ACCOUNT {
            return Err(GroupDmError::TooManyGroups);
        }
        Ok(())
    }
}
