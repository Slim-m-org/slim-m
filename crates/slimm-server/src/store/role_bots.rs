// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's managed role, looked up by bot id. Split out of `roles.rs` when
//! that file reached the 500-line ceiling. See
//! `docs/decisions/0028-bot-accounts.md`.

use crate::ids::{RoleId, UserId};
use crate::permissions::Permissions;

use super::Store;
use super::roles::Role;

impl Store {
    /// The role minted for this bot, if it still has one.
    pub async fn role_for_bot(&self, bot_user_id: UserId) -> anyhow::Result<Option<Role>> {
        let row = sqlx::query_as!(
            Role,
            r#"SELECT id AS "id!: RoleId", name AS "name!",
                      permissions AS "permissions!: Permissions",
                      is_everyone AS "is_everyone!: bool",
                      mentionable AS "mentionable!: bool", created_at AS "created_at!",
                      managed_bot_id AS "managed_bot_id: UserId",
                      position AS "position!: i64", hoist AS "hoist!: bool", color
               FROM roles WHERE managed_bot_id = ?"#,
            bot_user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }
}
