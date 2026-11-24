// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Invites: how someone joins a self-hosted deployment.
//!
//! Registration is open on an unclaimed server so the first account can claim
//! it, but a real deployment wants joining to be by invitation. An invite is a
//! short code with an optional use limit and expiry.
//!
//! A code is spent in one of two places, both through [`spend_invite`] so they
//! cannot drift apart:
//!
//! - [`Store::register_account`], which is how somebody without an account
//!   joins a claimed deployment. The spend happens in the same transaction as
//!   the account insert, so neither half can land without the other.
//! - [`Store::redeem_invite`], for an account that already exists and is
//!   spending a code for the role it grants.

mod redemption;
mod sweep;
pub use redemption::Redemption;
use redemption::maker_still_invites;
pub(super) use redemption::{apply_role_grant, record_redemption, spend_invite};

use rand_core::{OsRng, RngCore};

use super::{Store, now_ms};
use crate::ids::{RoleId, UserId};
use crate::permissions::Permissions;

/// Whose invites a caller sees and revokes.
#[derive(Debug, Clone, Copy, Default)]
pub struct InviteScope {
    /// Only this account's own; `None` for everyone's.
    pub creator: Option<UserId>,
    /// Besides their own, only invites granting a role this manager could grant by hand.
    pub grants: Option<GrantReach>,
}

/// Where a manager stands for granting a role by hand: [`InviteScope::grants`].
#[derive(Debug, Clone, Copy)]
pub struct GrantReach {
    pub manager: UserId,
    /// Only roles strictly below this position.
    pub below: i64,
    /// Only roles whose permissions all lie within these.
    pub holds: Permissions,
}

impl InviteScope {
    /// Every invite in the deployment.
    pub fn all() -> Self {
        Self::default()
    }

    fn parts(self) -> (Option<UserId>, Option<UserId>, i64, i64) {
        let creator = self.creator;
        match self.grants {
            Some(g) => (creator, Some(g.manager), g.below, g.holds.bits()),
            None => (creator, None, 0, 0),
        }
    }
}

/// A code someone can join with.
#[derive(Debug, Clone)]
pub struct Invite {
    pub code: String,
    pub max_uses: Option<i64>,
    pub uses: i64,
    pub expires_at: Option<i64>,
    pub created_at: i64,
    pub revoked: bool,
    /// A role every account redeeming this code receives.
    pub role_grant: Option<RoleId>,
    /// Who issued it; only listings fill this in.
    pub created_by_name: Option<String>,
}

impl Invite {
    /// Whether this invite can still be used right now.
    pub fn is_usable(&self, now: i64) -> bool {
        invite_usable(self.revoked, self.max_uses, self.uses, self.expires_at, now)
    }
}

/// The shared usability rule: not revoked, not past its use limit, not past
/// its expiry. [`Invite::is_usable`] and [`Store::check_invite`] both read
/// this out of a differently-shaped source (a full [`Invite`] versus a raw
/// query row), so this is the one place the rule itself is written down.
///
/// [`spend_invite`]'s SQL `WHERE` encodes the identical rule a third time and
/// cannot be unified with this one - sqlx checks a query's SQL at compile
/// time against a literal, not a runtime function call - which is why
/// `tests/it_accounts/invite_usability.rs` exists: it is what would catch the SQL copy
/// drifting from this one instead of a shared `fn`.
fn invite_usable(
    revoked: bool,
    max_uses: Option<i64>,
    uses: i64,
    expires_at: Option<i64>,
    now: i64,
) -> bool {
    !revoked
        && max_uses.is_none_or(|max| uses < max)
        && expires_at.is_none_or(|expiry| expiry > now)
}

/// What a valid invite discloses about itself, returned only for a code
/// [`Store::check_invite`] found usable. See that method's doc comment for
/// why the usable/unusable boundary is where this can be disclosed at all.
#[derive(Debug, Clone)]
pub struct InviteMetadata {
    /// The inviter's current display name, or `None` if their account has
    /// since been deleted: there is no name left to show, the same rule a
    /// message's author display name follows once its author is anonymized.
    pub invited_by: Option<String>,
    /// How many uses are left. `None` means unlimited.
    pub uses_remaining: Option<i64>,
    /// Unix milliseconds. `None` means the invite never expires.
    pub expires_at: Option<i64>,
}

/// The result of checking a code before signup.
#[derive(Debug, Clone)]
pub enum InviteCheck {
    /// Expired, spent, revoked, or never issued. Deliberately one variant
    /// for all four: see the module doc comment.
    Unusable,
    Usable(InviteMetadata),
}

/// Why redeeming failed. Deliberately one variant from the caller's point of
/// view: an expired code, a used-up code, and a code that never existed are all
/// reported the same way, so the endpoint cannot be used to mine valid codes.
#[derive(Debug)]
pub enum RedeemError {
    Unusable,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for RedeemError {
    fn from(err: sqlx::Error) -> Self {
        RedeemError::Internal(err.into())
    }
}

/// Generates a short, unambiguous code. Avoids characters people misread when
/// reading a code aloud or copying it off a screen.
fn generate_code() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let mut bytes = [0u8; 10];
    OsRng.fill_bytes(&mut bytes);
    bytes
        .iter()
        .map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char)
        .collect()
}

impl Store {
    /// Creates an invite.
    pub async fn create_invite(
        &self,
        created_by: UserId,
        role_grant: Option<RoleId>,
        max_uses: Option<i64>,
        expires_at: Option<i64>,
    ) -> anyhow::Result<Invite> {
        let code = generate_code();
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO invites (code, created_by, role_grant, max_uses, expires_at, created_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            code,
            created_by,
            role_grant,
            max_uses,
            expires_at,
            now
        )
        .execute(&self.pool)
        .await?;
        Ok(Invite {
            code,
            max_uses,
            uses: 0,
            expires_at,
            created_at: now,
            revoked: false,
            role_grant,
            created_by_name: None,
        })
    }

    /// Creates a member-made invite unless `created_by` already holds `cap`
    /// live ones; `None` means the cap was reached. One statement, so two
    /// racing requests cannot both slip under the cap.
    pub async fn create_invite_capped(
        &self,
        created_by: UserId,
        max_uses: Option<i64>,
        expires_at: Option<i64>,
        cap: i64,
    ) -> anyhow::Result<Option<Invite>> {
        let code = generate_code();
        let now = now_ms();
        let inserted = sqlx::query!(
            "INSERT INTO invites (code, created_by, max_uses, expires_at, created_at)
             SELECT ?1, ?2, ?3, ?4, ?5
             WHERE (SELECT COUNT(*) FROM invites
                    WHERE created_by = ?2 AND revoked_at IS NULL
                      AND (expires_at IS NULL OR expires_at > ?5)
                      AND (max_uses IS NULL OR uses < max_uses)) < ?6",
            code,
            created_by,
            max_uses,
            expires_at,
            now,
            cap
        )
        .execute(&self.pool)
        .await?;
        if inserted.rows_affected() == 0 {
            return Ok(None);
        }
        Ok(Some(Invite {
            code,
            max_uses,
            uses: 0,
            expires_at,
            created_at: now,
            revoked: false,
            role_grant: None,
            created_by_name: None,
        }))
    }

    /// Revokes every unspent invite whose creator no longer holds
    /// CREATE_INVITE, returning how many. Run when members stop being allowed
    /// to invite, so the codes they already made do not outlive the switch.
    pub async fn revoke_invites_without_rights(&self) -> anyhow::Result<u64> {
        let now = now_ms();
        let creators = sqlx::query_scalar!(
            r#"SELECT DISTINCT created_by AS "created_by!: UserId" FROM invites
               WHERE created_by IS NOT NULL AND revoked_at IS NULL"#
        )
        .fetch_all(&self.pool)
        .await?;
        let mut revoked = 0;
        for creator in creators {
            let rights = self.base_permissions(creator).await?;
            if rights.contains(crate::permissions::Permissions::CREATE_INVITE) {
                continue;
            }
            revoked += sqlx::query!(
                "UPDATE invites SET revoked_at = ? WHERE created_by = ? AND revoked_at IS NULL",
                now,
                creator
            )
            .execute(&self.pool)
            .await?
            .rows_affected();
        }
        Ok(revoked)
    }

    /// Invites, newest first, within `scope`: one account's own, or everyone's, or everyone's but
    /// the role-granting codes a manager could not grant by hand.
    ///
    /// The filter exists because a code is a credential. An invite row carries
    /// its own `code` and its `role_grant`, so an unscoped listing hands
    /// everybody who may issue an invite the live codes for everybody else's -
    /// including a single-use one an administrator minted to grant a specific
    /// person a role. `redeem` gives that role to whoever spends the code, so
    /// reading another account's code is enough to take the role meant for
    /// them. Only MANAGE_ROLES, which is what minting such an invite already
    /// requires, sees everyone's, and then only the roles it could grant itself.
    ///
    /// One page of at most `limit` rows, starting after the invite `before`
    /// names; an unknown `before` starts from the top rather than failing. An invite dead for
    /// longer than the sweep's grace is left out, as if swept, though a member's join keeps its row.
    pub async fn list_invites(
        &self,
        scope: InviteScope,
        before: Option<&str>,
        limit: i64,
    ) -> anyhow::Result<Vec<Invite>> {
        let (created_by, manager, below, holds) = scope.parts();
        let dead_before = now_ms() - sweep::DEAD_INVITE_GRACE_MS;
        let rows = sqlx::query!(
            r#"SELECT i.code AS "code!", i.max_uses, i.uses AS "uses!", i.expires_at,
                      i.created_at AS "created_at!", i.revoked_at,
                      i.role_grant AS "role_grant: RoleId",
                      u.display_name AS "created_by_name?: String"
               FROM invites i
               LEFT JOIN users u ON u.id = i.created_by AND u.deleted_at IS NULL
               WHERE (?1 IS NULL OR i.created_by = ?1)
                 AND (?2 IS NULL OR NOT EXISTS (SELECT 1 FROM invites c WHERE c.code = ?2)
                      OR (i.created_at, i.code) < (SELECT c.created_at, c.code FROM invites c WHERE c.code = ?2))
                 AND (?4 IS NULL OR i.role_grant IS NULL OR i.created_by = ?4
                      OR EXISTS (SELECT 1 FROM roles r WHERE r.id = i.role_grant
                                 AND r.is_everyone = 0 AND r.is_bots_role = 0
                                 AND r.managed_bot_id IS NULL AND r.position < ?5
                                 AND (r.permissions & ?6) = r.permissions))
                 AND NOT ((i.revoked_at IS NOT NULL AND i.revoked_at < ?7)
                      OR (i.expires_at IS NOT NULL AND i.expires_at < ?7)
                      OR (i.max_uses IS NOT NULL AND i.uses >= i.max_uses
                          AND COALESCE((SELECT MAX(r.redeemed_at) FROM invite_redemptions r
                                        WHERE r.code = i.code), i.created_at) < ?7))
               ORDER BY i.created_at DESC, i.code DESC
               LIMIT ?3"#,
            created_by,
            before,
            limit,
            manager,
            below,
            holds,
            dead_before
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| Invite {
                code: r.code,
                max_uses: r.max_uses,
                uses: r.uses,
                expires_at: r.expires_at,
                created_at: r.created_at,
                revoked: r.revoked_at.is_some(),
                role_grant: r.role_grant,
                created_by_name: r.created_by_name,
            })
            .collect())
    }

    /// Revokes an invite, only if it lies within `scope`.
    ///
    /// Answers whether a row changed, so a caller can tell "revoked" from
    /// "not yours, or already revoked, or never existed" - deliberately one
    /// answer for those three, the same reason [`Store::check_invite`] gives
    /// for collapsing its own unusable cases.
    ///
    /// The ownership test is a clause in the UPDATE rather than a read before
    /// it: checked separately, two requests could both read an invite as
    /// theirs to revoke and only one of them be right.
    pub async fn revoke_invite(&self, code: &str, scope: InviteScope) -> anyhow::Result<bool> {
        let now = now_ms();
        let (required_creator, manager, below, holds) = scope.parts();
        let result = sqlx::query!(
            "UPDATE invites SET revoked_at = ?1
             WHERE code = ?2 AND revoked_at IS NULL AND (?3 IS NULL OR created_by = ?3)
               AND (?4 IS NULL OR role_grant IS NULL OR created_by = ?4
                    OR EXISTS (SELECT 1 FROM roles r WHERE r.id = invites.role_grant
                               AND r.is_everyone = 0 AND r.is_bots_role = 0
                               AND r.managed_bot_id IS NULL AND r.position < ?5
                               AND (r.permissions & ?6) = r.permissions))",
            now,
            code,
            required_creator,
            manager,
            below,
            holds
        )
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    /// Whether `code` names an invite `scope` could have revoked, revoked already or not.
    pub async fn invite_exists(&self, code: &str, scope: InviteScope) -> anyhow::Result<bool> {
        let (required_creator, manager, below, holds) = scope.parts();
        let row = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM invites i
               WHERE i.code = ?1 AND (?2 IS NULL OR i.created_by = ?2)
                 AND (?3 IS NULL OR i.role_grant IS NULL OR i.created_by = ?3
                      OR EXISTS (SELECT 1 FROM roles r WHERE r.id = i.role_grant
                                 AND r.is_everyone = 0 AND r.is_bots_role = 0
                                 AND r.managed_bot_id IS NULL AND r.position < ?4
                                 AND (r.permissions & ?5) = r.permissions))"#,
            code,
            required_creator,
            manager,
            below,
            holds
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    /// Whether a code could be redeemed, without spending it. A thin
    /// boolean view over [`Store::check_invite`] for callers (and existing
    /// tests) that only need the yes/no answer.
    pub async fn invite_is_usable(&self, code: &str) -> anyhow::Result<bool> {
        Ok(matches!(
            self.check_invite(code).await?,
            InviteCheck::Usable(_)
        ))
    }

    /// Checks a code before asking someone to fill in a whole signup form,
    /// without spending it.
    ///
    /// The unusable branch answers identically for a code that is expired,
    /// already spent, revoked, or was never issued at all: [`InviteCheck`]
    /// has exactly one variant for all four, so there is no field this
    /// method (or its caller) could even accidentally leak that would let a
    /// caller distinguish one from another. The usable branch is different:
    /// a caller reaching it has already demonstrated they hold a working
    /// code, so [`InviteMetadata`] discloses what that code unlocks. That is
    /// new information about the deployment, not about the code itself, and
    /// it is safe only because proving the code works came first.
    pub async fn check_invite(&self, code: &str) -> anyhow::Result<InviteCheck> {
        let now = now_ms();
        let row = sqlx::query!(
            r#"SELECT max_uses, uses AS "uses!", expires_at, revoked_at,
                      u.display_name AS "invited_by?: String"
               FROM invites i
               LEFT JOIN users u ON u.id = i.created_by AND u.deleted_at IS NULL
               WHERE i.code = ?"#,
            code
        )
        .fetch_optional(&self.pool)
        .await?;

        let Some(row) = row else {
            return Ok(InviteCheck::Unusable);
        };
        let usable = invite_usable(
            row.revoked_at.is_some(),
            row.max_uses,
            row.uses,
            row.expires_at,
            now,
        );
        if !usable || !maker_still_invites(&mut *self.pool.acquire().await?, code).await? {
            return Ok(InviteCheck::Unusable);
        }

        Ok(InviteCheck::Usable(InviteMetadata {
            invited_by: row.invited_by,
            uses_remaining: row.max_uses.map(|max| max - row.uses),
            expires_at: row.expires_at,
        }))
    }
}
