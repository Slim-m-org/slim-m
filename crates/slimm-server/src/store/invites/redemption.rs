// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Redeeming and spending invites.

use std::collections::{HashMap, HashSet};

use sqlx::{QueryBuilder, SqliteConnection};

use super::{InviteScope, RedeemError};
use crate::ids::{RoleId, UserId};
use crate::permissions::{Permissions, evaluate};
use crate::store::space_owner::live_owner;
use crate::store::{Store, now_ms};

/// What one redemption did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Redemption {
    /// Whether this call spent a use; `false` for a retry by someone who already redeemed the code.
    pub fresh: bool,
    /// The role this call gave the redeemer, if it gave one.
    pub granted: Option<RoleId>,
}

impl Store {
    /// Spends one use of an invite and applies any role it grants.
    ///
    /// The spend is a single conditional UPDATE, so the use limit holds under
    /// concurrent redemptions: two people racing the last slot cannot both win,
    /// because only one UPDATE can match.
    ///
    /// Reports whether this call actually spent a use, so the caller announces only a fresh
    /// redemption, and which role it gave, so the caller can announce that too.
    pub async fn redeem_invite(
        &self,
        code: &str,
        user_id: UserId,
    ) -> Result<Redemption, RedeemError> {
        let now = now_ms();
        // BEGIN IMMEDIATE: reads whether the caller already redeemed before writing, so two retries cannot each spend a use.
        let mut tx = self.begin_write().await?;

        // A retry by an already-redeemed user is a no-op: the role is granted and no second use is spent; see SRV5.
        let already_redeemed = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM invite_redemptions
               WHERE code = ? AND user_id = ?"#,
            code,
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .is_some();
        if already_redeemed {
            tx.commit().await?;
            return Ok(Redemption {
                fresh: false,
                granted: None,
            });
        }

        let Some(role_grant) = spend_invite(&mut tx, code, now).await? else {
            return Err(RedeemError::Unusable);
        };
        record_redemption(&mut tx, code, user_id, now).await?;

        let mut granted = None;
        if let Some(role_id) = role_grant {
            if !redeemer_may_take(&mut tx, user_id, role_id).await? {
                tracing::info!(%role_id, "a manager redeemed an invite for a role they could not grant; joined without it");
            } else if apply_role_grant(&mut tx, code, user_id, role_id).await? {
                granted = Some(role_id);
            }
        }

        tx.commit().await?;
        Ok(Redemption {
            fresh: true,
            granted,
        })
    }

    /// The invite each of `ids` first registered through, for surfacing to a
    /// BAN_MEMBERS moderator as a ban-evasion signal (see MOD9, building on
    /// SRV5's recording of this table). An id with more than one redemption
    /// keeps only the earliest - the registration one, since a later
    /// redemption is somebody spending a code on an account they already
    /// held. An id with no redemption at all is simply absent, the same
    /// contract [`Store::user_profiles`] has for a missing id.
    ///
    /// Chunked under SQLite's bind limit the same way `user_profiles` is.
    pub async fn registration_invite_codes(
        &self,
        ids: &[UserId],
    ) -> anyhow::Result<HashMap<UserId, String>> {
        use sqlx::Row;

        if ids.is_empty() {
            return Ok(HashMap::new());
        }
        let mut out = HashMap::new();
        for chunk in ids.chunks(crate::store::MAX_IDS_PER_QUERY) {
            // Built not `query!` (variable id list); ROW_NUMBER keeps one row per user - earliest redemption, ties broken by code - so two same-millisecond redemptions cannot return two rows.
            let mut builder = QueryBuilder::new(
                "SELECT user_id, code FROM (SELECT user_id, code, ROW_NUMBER() OVER \
                 (PARTITION BY user_id ORDER BY redeemed_at, code) AS rn \
                 FROM invite_redemptions WHERE user_id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")) WHERE rn = 1");
            for row in builder.build().fetch_all(&self.pool).await? {
                out.insert(row.try_get("user_id")?, row.try_get("code")?);
            }
        }
        Ok(out)
    }

    /// Which of `codes` name an invite within `scope`, the filter [`Store::list_invites`] applies.
    pub async fn invite_codes_within(
        &self,
        codes: &[String],
        scope: InviteScope,
    ) -> anyhow::Result<HashSet<String>> {
        use sqlx::Row;

        let (creator, manager, below, holds) = scope.parts();
        let mut out = HashSet::new();
        for chunk in codes.chunks(crate::store::MAX_IDS_PER_QUERY) {
            let mut builder = QueryBuilder::new("SELECT i.code FROM invites i WHERE i.code IN (");
            let mut separated = builder.separated(", ");
            for code in chunk {
                separated.push_bind(code);
            }
            builder.push(")");
            if let Some(creator) = creator {
                builder.push(" AND i.created_by = ").push_bind(creator);
            }
            if let Some(manager) = manager {
                builder
                    .push(" AND (i.role_grant IS NULL OR i.created_by = ")
                    .push_bind(manager)
                    .push(
                        " OR EXISTS (SELECT 1 FROM roles r WHERE r.id = i.role_grant \
                         AND r.is_everyone = 0 AND r.is_bots_role = 0 \
                         AND r.managed_bot_id IS NULL AND r.position < ",
                    )
                    .push_bind(below)
                    .push(" AND (r.permissions & ")
                    .push_bind(holds)
                    .push(") = r.permissions))");
            }
            for row in builder.build().fetch_all(&self.pool).await? {
                out.insert(row.try_get("code")?);
            }
        }
        Ok(out)
    }
}

/// Whether the maker of `code` may still invite: a code whose maker lost the right is dead
/// whatever its row says. A code with no row, or no maker on record, is left to the spend itself.
pub(in crate::store) async fn maker_still_invites(
    conn: &mut SqliteConnection,
    code: &str,
) -> Result<bool, sqlx::Error> {
    let row = sqlx::query!(
        r#"SELECT i.created_by AS "maker: UserId",
                  EXISTS (SELECT 1 FROM pending_members pm WHERE pm.user_id = i.created_by)
                      AS "pending!: bool",
                  COALESCE((SELECT s.members_can_invite FROM space_settings s WHERE s.id = 1), 0)
                      AS "members_invite!: bool"
           FROM invites i WHERE i.code = ?"#,
        code
    )
    .fetch_optional(&mut *conn)
    .await?;
    let Some(row) = row else {
        return Ok(true);
    };
    let Some(maker) = row.maker else {
        return Ok(true);
    };
    if row.members_invite {
        return Ok(true);
    }
    if row.pending {
        return Ok(false);
    }
    let standing = Standing::of(conn, maker).await?;
    Ok(standing.granted.contains(Permissions::CREATE_INVITE))
}

/// Spends one use of `code` inside an open transaction.
///
/// `Ok(None)` means the code was unusable: expired, spent, revoked, never
/// there, or made by someone who can no longer invite. `Ok(Some(grant))` means
/// this caller won the use, and `grant` is the role the invite carries, if any.
///
/// A single conditional UPDATE is what makes the use limit hold under
/// concurrency: two callers racing the last slot cannot both match. It lives
/// here as a free function so registration ([`Store::register_account`]) and
/// redemption by an existing account ([`Store::redeem_invite`]) spend a code
/// through exactly the same statement, and cannot drift into two different
/// notions of what "usable" means.
pub(in crate::store) async fn spend_invite(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    code: &str,
    now: i64,
) -> Result<Option<Option<RoleId>>, sqlx::Error> {
    if !maker_still_invites(tx, code).await? {
        return Ok(None);
    }
    let claimed = sqlx::query!(
        r#"UPDATE invites SET uses = uses + 1
           WHERE code = ?
             AND revoked_at IS NULL
             AND (max_uses IS NULL OR uses < max_uses)
             AND (expires_at IS NULL OR expires_at > ?)
           RETURNING role_grant AS "role_grant: RoleId""#,
        code,
        now
    )
    .fetch_optional(&mut **tx)
    .await?;
    Ok(claimed.map(|row| row.role_grant))
}

/// Records that `user_id` redeemed `code`, the (code, user) key that makes a
/// repeat redemption a no-op. Called by both spend paths after the invite's
/// own use has been spent, so the code and the user both exist and the two
/// foreign keys hold; see SRV5. The `redeemed_at` is informational only - the
/// primary key is what enforces one redemption per pair.
pub(in crate::store) async fn record_redemption(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    code: &str,
    user_id: UserId,
    now: i64,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "INSERT INTO invite_redemptions (code, user_id, redeemed_at) VALUES (?, ?, ?)",
        code,
        user_id,
        now
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Gives `user_id` the role `code` grants, but only while its creator could still grant it by
/// hand: a creator demoted or removed since the invite was made no longer hands out the role.
/// Answers whether the member holds the role now and did not before.
pub(in crate::store) async fn apply_role_grant(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    code: &str,
    user_id: UserId,
    role_id: RoleId,
) -> Result<bool, sqlx::Error> {
    if !creator_still_grants(tx, code, role_id).await? {
        tracing::info!(%role_id, "an invite's creator can no longer grant its role; joined without it");
        return Ok(false);
    }
    let inserted = sqlx::query!(
        "INSERT OR IGNORE INTO member_roles (user_id, role_id) VALUES (?, ?)",
        user_id,
        role_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(inserted.rows_affected() > 0)
}

/// The checks `http::invites::resolve_grant` ran at creation, against the creator as they are now.
async fn creator_still_grants(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    code: &str,
    role_id: RoleId,
) -> Result<bool, sqlx::Error> {
    let grant = sqlx::query!(
        r#"SELECT u.id AS "creator!: UserId",
                  r.permissions AS "permissions!: Permissions", r.position AS "position!: i64",
                  (r.managed_bot_id IS NOT NULL OR r.is_bots_role = 1) AS "bot_held!: bool"
           FROM invites i JOIN roles r ON r.id = ?
           JOIN users u ON u.id = i.created_by AND u.deleted_at IS NULL
           WHERE i.code = ?
             AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)"#,
        role_id,
        code
    )
    .fetch_optional(&mut **tx)
    .await?;
    let Some(grant) = grant.filter(|g| !g.bot_held) else {
        return Ok(false);
    };
    let creator = Standing::of(tx, grant.creator).await?;
    Ok(creator.grants(grant.position, grant.permissions))
}

/// Refuses a manager climbing the ladder through an invite: someone who manages roles gets the
/// invite's role only if they could have granted it to themselves by hand.
async fn redeemer_may_take(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    redeemer: UserId,
    role_id: RoleId,
) -> Result<bool, sqlx::Error> {
    let role = sqlx::query!(
        r#"SELECT permissions AS "permissions!: Permissions", position AS "position!: i64"
           FROM roles WHERE id = ?"#,
        role_id
    )
    .fetch_optional(&mut **tx)
    .await?;
    let Some(role) = role else {
        return Ok(false);
    };
    let standing = Standing::of(tx, redeemer).await?;
    Ok(!standing.granted.contains(Permissions::MANAGE_ROLES)
        || standing.grants(role.position, role.permissions))
}

/// Where one account stands for granting a role by hand, read inside the redemption.
struct Standing {
    is_owner: bool,
    granted: Permissions,
    top: Option<i64>,
}

impl Standing {
    async fn of(conn: &mut SqliteConnection, user_id: UserId) -> Result<Self, sqlx::Error> {
        let is_owner = live_owner(conn).await? == Some(user_id);
        let held = sqlx::query!(
            r#"SELECT permissions AS "permissions!: Permissions", position AS "position!: i64",
                  is_everyone AS "is_everyone!: bool"
           FROM roles
           WHERE is_everyone = 1
              OR id IN (SELECT role_id FROM member_roles WHERE user_id = ?)"#,
            user_id
        )
        .fetch_all(&mut *conn)
        .await?;
        let everyone = held
            .iter()
            .filter(|r| r.is_everyone)
            .fold(Permissions::NONE, |bits, r| bits.union(r.permissions));
        let roles: Vec<Permissions> = held
            .iter()
            .filter(|r| !r.is_everyone)
            .map(|r| r.permissions)
            .collect();
        let granted = match is_owner {
            true => Permissions::ALL,
            false => evaluate(everyone, &roles, None, &[], None),
        };
        let top = held
            .iter()
            .filter(|r| !r.is_everyone)
            .map(|r| r.position)
            .max();
        Ok(Self {
            is_owner,
            granted,
            top,
        })
    }

    /// Whether this account could grant a role at `position` carrying `permissions` by hand.
    fn grants(&self, position: i64, permissions: Permissions) -> bool {
        let ranks = self.is_owner || self.top.is_some_and(|top| position < top);
        ranks
            && self.granted.contains(Permissions::MANAGE_ROLES)
            && self.granted.contains(permissions)
    }
}
