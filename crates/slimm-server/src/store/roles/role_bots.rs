// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's managed role, looked up by bot id, and the shared Bots role. Split out of `roles.rs` when
//! that file reached the 500-line ceiling. See
//! `docs/decisions/0028-bot-accounts.md`.

use sqlx::SqliteConnection;

use crate::ids::{RoleId, UserId};
use crate::permissions::Permissions;

use super::super::Store;
use super::Role;

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
                      is_bots_role AS "is_bots_role!: bool",
                      position AS "position!: i64", hoist AS "hoist!: bool", color
               FROM roles WHERE managed_bot_id = ?"#,
            bot_user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }
}

/// The role every bot holds, made on first use so a deployment without bots has none.
pub(in crate::store) async fn ensure_bots_role(
    conn: &mut SqliteConnection,
    now: i64,
) -> sqlx::Result<RoleId> {
    let existing =
        sqlx::query_scalar!(r#"SELECT id AS "id!: RoleId" FROM roles WHERE is_bots_role = 1"#)
            .fetch_optional(&mut *conn)
            .await?;
    if let Some(id) = existing {
        return Ok(id);
    }
    let id = RoleId::generate();
    sqlx::query!(
        "INSERT INTO roles (id, name, permissions, is_everyone, created_at, is_bots_role)
         VALUES (?, 'Bots', 0, 0, ?, 1)",
        id,
        now
    )
    .execute(&mut *conn)
    .await?;
    Ok(id)
}

/// Mints a bot's own role and assigns it; only a bot holding permissions has one.
pub(in crate::store) async fn insert_managed_role(
    conn: &mut SqliteConnection,
    bot_user_id: UserId,
    name: &str,
    permissions: Permissions,
    now: i64,
) -> sqlx::Result<RoleId> {
    let role_id = RoleId::generate();
    let bits = permissions.bits();
    sqlx::query!(
        "INSERT INTO roles (id, name, permissions, is_everyone, created_at, managed_bot_id)
         VALUES (?, ?, ?, 0, ?, ?)",
        role_id,
        name,
        bits,
        now,
        bot_user_id
    )
    .execute(&mut *conn)
    .await?;
    assign_to_bot(conn, bot_user_id, role_id).await?;
    Ok(role_id)
}

pub(in crate::store) async fn assign_to_bot(
    conn: &mut SqliteConnection,
    bot_user_id: UserId,
    role_id: RoleId,
) -> sqlx::Result<()> {
    sqlx::query!(
        "INSERT OR IGNORE INTO member_roles (user_id, role_id) VALUES (?, ?)",
        bot_user_id,
        role_id
    )
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Removes a bot's own role with its assignment and any overwrites aimed at it.
pub(in crate::store) async fn delete_managed_role(
    conn: &mut SqliteConnection,
    role_id: RoleId,
) -> sqlx::Result<()> {
    sqlx::query!(
        "DELETE FROM channel_overwrites WHERE target_type = 'role' AND target_id = ?",
        role_id
    )
    .execute(&mut *conn)
    .await?;
    sqlx::query!(
        "DELETE FROM category_overwrites WHERE target_type = 'role' AND target_id = ?",
        role_id
    )
    .execute(&mut *conn)
    .await?;
    sqlx::query!("DELETE FROM member_roles WHERE role_id = ?", role_id)
        .execute(&mut *conn)
        .await?;
    sqlx::query!("DELETE FROM roles WHERE id = ?", role_id)
        .execute(&mut *conn)
        .await?;
    Ok(())
}

impl Store {
    /// Whether this id is a live bot with a token record; a module's principal has none.
    pub async fn is_bot_account(&self, user_id: UserId) -> anyhow::Result<bool> {
        let row = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM users u
               WHERE u.id = ? AND u.is_bot = 1 AND u.deleted_at IS NULL
                 AND EXISTS (SELECT 1 FROM bot_tokens t WHERE t.bot_user_id = u.id)"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }
}
