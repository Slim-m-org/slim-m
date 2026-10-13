// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Role CRUD and member role assignment.
//!
//! Two authorization concerns sit above this module, in `http::roles`,
//! because they need the caller's own identity: a role's permissions, on
//! create, on update, and again on every assignment, must never include a bit
//! the caller does not themselves hold, or granting a role becomes a way to
//! hand out access nobody actually approved. What lives here instead is the
//! invariant only this module can see across every caller: the deployment
//! must always keep at least one administrator, since losing the last one has
//! no recovery path short of direct database surgery. Every mutation that
//! could remove someone's last route to ADMINISTRATOR checks that inside the
//! same transaction as the write, and rolls back rather than commit a state
//! with zero administrators.

use sqlx::{QueryBuilder, SqliteConnection};

use super::{Store, now_ms};
use crate::ids::{RoleId, UserId};
use crate::permissions::Permissions;

/// A role: a named, reusable permission set members can hold.
#[derive(Debug, Clone)]
pub struct Role {
    pub id: RoleId,
    pub name: String,
    pub permissions: Permissions,
    pub is_everyone: bool,
    /// Whether an ordinary member can wake this role's members with
    /// `@[Role Name]` with no permission of their own; see
    /// `push::recipients::resolved_mentions`. Never consulted for
    /// `is_everyone`, which the reserved `@everyone`/`@here` words already
    /// cover under `Permissions::MENTION_EVERYONE`.
    pub mentionable: bool,
    pub created_at: i64,
    /// The bot this role was minted for, if any - informational only. See
    /// `docs/decisions/0028-bot-accounts.md`.
    pub managed_bot_id: Option<UserId>,
    /// Hierarchy order: higher sorts first in [`Store::list_roles`] and is
    /// the value `store::role_reorder`'s escalation guard compares a caller's
    /// own highest role against. `@everyone` stays at its bootstrap default
    /// (0) forever - it is never a member of `member_roles`, so nothing ever
    /// reorders it - and every other role's position only ever comes from an
    /// explicit reorder or the column's own `DEFAULT 0` at creation.
    pub position: i64,
    /// Whether the member pane gives this role's members their own section.
    pub hoist: bool,
    /// An index into the client's role palette, below [`ROLE_COLOR_COUNT`];
    /// `None` leaves the colour the client derives from the id.
    pub color: Option<i64>,
}

/// How many colours the role palette holds; the client's palette is the same length.
pub const ROLE_COLOR_COUNT: usize = 10;

/// Why a role mutation was refused.
#[derive(Debug)]
pub enum RoleGuardError {
    /// `@everyone` is the base of every permission evaluation, and the
    /// partial unique index on `is_everyone` already guarantees there is
    /// exactly one; deleting it would leave the evaluator with no base.
    IsEveryone,
    /// This change would leave the deployment with no administrator.
    LastAdministrator,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for RoleGuardError {
    fn from(err: sqlx::Error) -> Self {
        RoleGuardError::Internal(err.into())
    }
}

impl From<anyhow::Error> for RoleGuardError {
    fn from(err: anyhow::Error) -> Self {
        RoleGuardError::Internal(err)
    }
}

/// The outcome of a create, which is idempotent by client-supplied id and so
/// may be a retry; see [`Store::create_role_with_id`].
#[derive(Debug, Clone, Copy)]
pub struct CreatedRole {
    pub id: RoleId,
    /// False when this id already named a role, so the call was a retry of a
    /// create that already succeeded. The caller publishes `RoleChanged`
    /// only when this is true, or a retry would wake every connected client
    /// a second time for a role they already know about.
    pub fresh: bool,
}

/// Why creating a role by id failed outright, rather than succeeding fresh
/// or as a retry.
#[derive(Debug)]
pub enum CreateRoleError {
    /// This id already names the deployment's singleton `@everyone` role.
    /// `roles` holds it in the same id namespace as every ordinary role, so
    /// a colliding id must never be handed back as if it were the caller's
    /// own new role - the same reason
    /// [`super::messages::SendError::IdConflict`] refuses to alias a
    /// foreign message rather than returning it.
    ///
    /// Scoped to `is_everyone` only: it is the sole structural marker this
    /// table carries. The bootstrap `admin` role is not otherwise
    /// distinguished from any role a MANAGE_ROLES holder creates for
    /// themselves - that is what `create_role` is for - so there is no
    /// column here to key a second case off.
    IdConflict,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for CreateRoleError {
    fn from(err: sqlx::Error) -> Self {
        CreateRoleError::Internal(err.into())
    }
}

impl From<anyhow::Error> for CreateRoleError {
    fn from(err: anyhow::Error) -> Self {
        CreateRoleError::Internal(err)
    }
}

impl Store {
    /// Creates a role. Exactly one role carries `is_everyone`; that base role
    /// applies to every member whether or not they hold it explicitly. A partial
    /// unique index enforces the singleton, so a second `@everyone` role is
    /// rejected here rather than corrupting the evaluation base.
    ///
    /// Idempotent by `id`: a retry with the same id returns the row already
    /// stored under it rather than inserting again, the same contract
    /// [`super::messages::Store::send_message`] gives a message send. Uses
    /// [`Store::begin_write`] (`BEGIN IMMEDIATE`) rather than a bare pool
    /// execute, for the same reason `send_message` does: this reads the id
    /// before it writes.
    ///
    /// [`Store::create_role`] is the convenience form for a caller with no
    /// client-supplied id of its own; it mints one and always sees
    /// [`CreatedRole::fresh`] true, since a freshly generated UUIDv7 id
    /// cannot already be in use.
    /// `mentionable` always starts false (the column's own `DEFAULT 0`, not
    /// repeated here): a role must be opted in to `@[Role Name]` waking
    /// anyone through [`Store::update_role`] after creation, never at birth,
    /// matching the deny-by-default posture every other permission on a new
    /// role already has.
    pub async fn create_role_with_id(
        &self,
        id: RoleId,
        name: &str,
        permissions: Permissions,
        is_everyone: bool,
    ) -> Result<CreatedRole, CreateRoleError> {
        let mut tx = self.begin_write().await?;

        let existing = sqlx::query_scalar!(
            r#"SELECT is_everyone AS "is_everyone!: bool" FROM roles WHERE id = ?"#,
            id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(existing_is_everyone) = existing {
            tx.commit().await?;
            if existing_is_everyone {
                return Err(CreateRoleError::IdConflict);
            }
            return Ok(CreatedRole { id, fresh: false });
        }

        let now = now_ms();
        let bits = permissions.bits();
        let is_everyone = i64::from(is_everyone);
        let result = sqlx::query!(
            "INSERT INTO roles (id, name, permissions, is_everyone, created_at)
             VALUES (?, ?, ?, ?, ?)",
            id,
            name,
            bits,
            is_everyone,
            now
        )
        .execute(&mut *tx)
        .await;

        match result {
            Ok(_) => {
                tx.commit().await?;
                Ok(CreatedRole { id, fresh: true })
            }
            Err(sqlx::Error::Database(e)) if e.is_unique_violation() => Err(
                CreateRoleError::Internal(anyhow::anyhow!("an @everyone role already exists")),
            ),
            Err(e) => Err(e.into()),
        }
    }

    /// Creates a role with a server-minted id; see
    /// [`Store::create_role_with_id`] for the idempotent form a caller with
    /// a client-supplied id wants instead.
    ///
    /// [`CreateRoleError::IdConflict`] cannot happen here: a freshly
    /// generated UUIDv7 cannot already name the `@everyone` role, so the
    /// only error this ever actually surfaces is `Internal`.
    pub async fn create_role(
        &self,
        name: &str,
        permissions: Permissions,
        is_everyone: bool,
    ) -> anyhow::Result<RoleId> {
        match self
            .create_role_with_id(RoleId::generate(), name, permissions, is_everyone)
            .await
        {
            Ok(created) => Ok(created.id),
            Err(CreateRoleError::IdConflict) => {
                anyhow::bail!("a freshly generated role id collided with an existing row")
            }
            Err(CreateRoleError::Internal(err)) => Err(err),
        }
    }

    /// Every role, highest position first.
    pub async fn list_roles(&self) -> anyhow::Result<Vec<Role>> {
        let rows = sqlx::query_as!(
            Role,
            r#"SELECT id AS "id!: RoleId", name AS "name!",
                      permissions AS "permissions!: Permissions",
                      is_everyone AS "is_everyone!: bool",
                      mentionable AS "mentionable!: bool", created_at AS "created_at!",
                      managed_bot_id AS "managed_bot_id: UserId",
                      position AS "position!: i64", hoist AS "hoist!: bool", color
               FROM roles ORDER BY position DESC, created_at"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Fetches one role by id.
    pub async fn role(&self, role_id: RoleId) -> anyhow::Result<Option<Role>> {
        let row = sqlx::query_as!(
            Role,
            r#"SELECT id AS "id!: RoleId", name AS "name!",
                      permissions AS "permissions!: Permissions",
                      is_everyone AS "is_everyone!: bool",
                      mentionable AS "mentionable!: bool", created_at AS "created_at!",
                      managed_bot_id AS "managed_bot_id: UserId",
                      position AS "position!: i64", hoist AS "hoist!: bool", color
               FROM roles WHERE id = ?"#,
            role_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    // Bot-managed-role reads live in `role_bots.rs`; see that file's own doc.

    /// Who holds a role, for a caller that has to notify them about something
    /// their membership decides.
    ///
    /// Bounded by the role's own membership rather than by the deployment, and
    /// the only caller is the overwrite handler, which needs the set *before*
    /// it writes; see [`crate::http::overwrites`].
    pub async fn members_with_role(&self, role_id: RoleId) -> anyhow::Result<Vec<UserId>> {
        let rows = sqlx::query!(
            r#"SELECT user_id AS "user_id!: UserId" FROM member_roles WHERE role_id = ?"#,
            role_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| r.user_id).collect())
    }

    /// Deletes a role. `Ok(None)` if it does not exist. Refuses to delete
    /// `@everyone`, and refuses if doing so would leave no administrator.
    ///
    /// Clears the role's channel overwrites by hand: no foreign key ties an
    /// overwrite to a role (the column is polymorphic across role and member
    /// targets), so they would otherwise sit inert but unreachable and the
    /// table would accumulate dead rows. `member_roles` does cascade away on
    /// the role's own foreign key.
    pub async fn delete_role(&self, role_id: RoleId) -> Result<Option<()>, RoleGuardError> {
        // Reads the role and the administrator count before deciding, so it
        // must hold the write lock from the start; see `Store::begin_write`.
        let mut tx = self.begin_write().await?;

        let is_everyone = sqlx::query_scalar!(
            r#"SELECT is_everyone AS "is_everyone!: bool" FROM roles WHERE id = ?"#,
            role_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(is_everyone) = is_everyone else {
            return Ok(None);
        };
        if is_everyone {
            return Err(RoleGuardError::IsEveryone);
        }

        // Cleared by hand, since no FK covers them; see the note on this
        // function.
        sqlx::query!(
            "DELETE FROM channel_overwrites WHERE target_type = 'role' AND target_id = ?",
            role_id
        )
        .execute(&mut *tx)
        .await?;
        // member_roles cascades away on the role's own foreign key.
        sqlx::query!("DELETE FROM roles WHERE id = ?", role_id)
            .execute(&mut *tx)
            .await?;

        if administrator_count(&mut tx).await? == 0 {
            return Err(RoleGuardError::LastAdministrator);
        }
        tx.commit().await?;
        Ok(Some(()))
    }

    /// Non-`@everyone` roles for a batch of users, as (id, name) pairs, in one query no
    /// matter how many are asked about - the same batching shape
    /// [`Store::reactions_for_messages`] uses to keep a page of messages from
    /// paying one query per row. `GET /members` is the caller that actually
    /// needs this: it pages up to 200 members at once, and a naive
    /// per-member roles lookup would be exactly the N+1 that shape exists to
    /// avoid.
    ///
    /// `@everyone` is deliberately excluded: every member holds it, so
    /// including it would put a meaningless badge on every row. A user with
    /// nothing beyond that base role is simply absent from the result, the
    /// same "missing means none" contract [`Store::user_profiles`] already
    /// has for a batch of ids.
    ///
    /// The id rides along with the name because a role name is not unique -
    /// nothing in the schema stops two roles being called `mod` - so a client
    /// deciding which roles a member holds by matching names would light up
    /// both of them. The name is what a badge renders; the id is what an
    /// assignment is made against.
    pub async fn roles_for_users(
        &self,
        user_ids: &[UserId],
    ) -> anyhow::Result<Vec<(UserId, Vec<(RoleId, String)>)>> {
        if user_ids.is_empty() {
            return Ok(Vec::new());
        }

        // Built rather than a fixed `query!` because the id list is variable
        // length and SQLite has no array binding.
        let mut builder = QueryBuilder::new(
            "SELECT mr.user_id AS user_id, r.id AS role_id, r.name AS name \
             FROM member_roles mr JOIN roles r ON r.id = mr.role_id \
             WHERE r.is_everyone = 0 AND mr.user_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in user_ids {
            separated.push_bind(*id);
        }
        builder.push(") ORDER BY mr.user_id, r.position DESC, r.created_at");

        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        let mut grouped: Vec<(UserId, Vec<(RoleId, String)>)> = Vec::new();
        for row in rows {
            let user_id: UserId = row.try_get("user_id")?;
            let role = (row.try_get("role_id")?, row.try_get("name")?);
            match grouped.iter_mut().find(|(id, _)| *id == user_id) {
                Some((_, roles)) => roles.push(role),
                None => grouped.push((user_id, vec![role])),
            }
        }
        Ok(grouped)
    }

    /// Revokes a role from a member. Idempotent: unassigning a role the
    /// member does not hold still succeeds, the same as [`Store::assign_role`]
    /// is idempotent the other way. Refuses if doing so would leave no
    /// administrator. Answers whether the member held it.
    pub async fn unassign_role(
        &self,
        user_id: UserId,
        role_id: RoleId,
    ) -> Result<bool, RoleGuardError> {
        let mut tx = self.begin_write().await?;
        let removed = sqlx::query!(
            "DELETE FROM member_roles WHERE user_id = ? AND role_id = ?",
            user_id,
            role_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if administrator_count(&mut tx).await? == 0 {
            return Err(RoleGuardError::LastAdministrator);
        }
        tx.commit().await?;
        Ok(removed > 0)
    }
}

/// Counts live users who currently hold ADMINISTRATOR, whether through the
/// `@everyone` base (which applies with no explicit assignment) or a role
/// assigned to them directly.
///
/// Excludes a webhook's principal even though it is a live `users` row that
/// would otherwise inherit `@everyone`'s grant like anyone else: a webhook
/// holds no roles at all (`docs/decisions/0030-incoming-webhooks.md`), and a
/// principal that is not a member must never be miscounted by this query the
/// way 0015 already records happening once for a different gap.
///
/// Callers run this inside their own transaction, after the mutation under
/// test, so it sees a write that has not committed yet; that is the whole
/// point, since the caller rolls back by simply not committing if this comes
/// back zero.
pub(super) async fn administrator_count(conn: &mut SqliteConnection) -> Result<i64, sqlx::Error> {
    let admin_bit = Permissions::ADMINISTRATOR.bits();
    sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!: i64" FROM users u
           WHERE u.deleted_at IS NULL AND u.is_webhook = 0
           AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id) AND (
               EXISTS (SELECT 1 FROM roles WHERE is_everyone = 1 AND (permissions & ?) != 0)
               OR EXISTS (
                   SELECT 1 FROM member_roles mr JOIN roles r ON r.id = mr.role_id
                   WHERE mr.user_id = u.id AND (r.permissions & ?) != 0
               )
           )"#,
        admin_bit,
        admin_bit
    )
    .fetch_one(&mut *conn)
    .await
}
