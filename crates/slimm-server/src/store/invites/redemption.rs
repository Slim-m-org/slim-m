// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Redeeming and spending invites.

use std::collections::HashMap;

use sqlx::QueryBuilder;

use super::RedeemError;
use crate::ids::{RoleId, UserId};
use crate::permissions::{Permissions, evaluate};
use crate::store::space_owner::live_owner;
use crate::store::{Store, now_ms};

impl Store {
    /// Spends one use of an invite and applies any role it grants.
    ///
    /// The spend is a single conditional UPDATE, so the use limit holds under
    /// concurrent redemptions: two people racing the last slot cannot both win,
    /// because only one UPDATE can match.
    ///
    /// Returns whether this call actually spent a use: `false` for the
    /// already-redeemed retry below, so the caller can publish
    /// `Event::MemberJoined` only for a fresh redemption and not fan out a
    /// join announcement on every idempotent retry.
    pub async fn redeem_invite(&self, code: &str, user_id: UserId) -> Result<bool, RedeemError> {
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
            return Ok(false);
        }

        let Some(role_grant) = spend_invite(&mut tx, code, now).await? else {
            return Err(RedeemError::Unusable);
        };
        record_redemption(&mut tx, code, user_id, now).await?;

        if let Some(role_id) = role_grant {
            apply_role_grant(&mut tx, code, user_id, role_id).await?;
        }

        tx.commit().await?;
        Ok(true)
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
}

/// Spends one use of `code` inside an open transaction.
///
/// `Ok(None)` means the code was unusable: expired, spent, revoked, or never
/// there. `Ok(Some(grant))` means this caller won the use, and `grant` is the
/// role the invite carries, if any.
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
pub(in crate::store) async fn apply_role_grant(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    code: &str,
    user_id: UserId,
    role_id: RoleId,
) -> Result<(), sqlx::Error> {
    if !creator_still_grants(tx, code, role_id).await? {
        tracing::info!(%role_id, "an invite's creator can no longer grant its role; joined without it");
        return Ok(());
    }
    sqlx::query!(
        "INSERT OR IGNORE INTO member_roles (user_id, role_id) VALUES (?, ?)",
        user_id,
        role_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
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
    let is_owner = live_owner(tx).await? == Some(grant.creator);
    let held = sqlx::query!(
        r#"SELECT permissions AS "permissions!: Permissions", position AS "position!: i64",
                  is_everyone AS "is_everyone!: bool"
           FROM roles
           WHERE is_everyone = 1
              OR id IN (SELECT role_id FROM member_roles WHERE user_id = ?)"#,
        grant.creator
    )
    .fetch_all(&mut **tx)
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
    let ranks = is_owner || top.is_some_and(|top| grant.position < top);
    Ok(ranks && granted.contains(Permissions::MANAGE_ROLES) && granted.contains(grant.permissions))
}
