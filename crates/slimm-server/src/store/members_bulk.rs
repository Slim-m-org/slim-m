// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing or timing out several members as one act.
//!
//! The case this exists for is the one MOD2's member search already made
//! findable and gave no way to answer: a wave of throwaway accounts
//! registered through the same invite. Finding thirty of them and then
//! removing them one confirmation at a time is the gap.
//!
//! **Neither verb reimplements the single one.** Both run
//! [`remove_one`] and [`timeout_one`], the bodies lifted out of
//! [`Store::remove_from_space`] and [`Store::set_member_timeout`], so the
//! session teardown, the invite revocation, the replace-not-refuse rule and
//! the audit row are the same code rather than the same intention. This is the
//! rule `messages_bulk` states and the reason it states it: a bulk path that
//! quietly does less than the single one is worse than no bulk path at all.
//!
//! **One transaction for the whole batch**, so a target the caller may not act
//! on cannot leave an earlier one already removed while the request fails.
//! That is `canvas_ops_apply`'s validate-all-then-write rule, and it is why
//! the last-administrator refusal rolls the batch back rather than stopping
//! part-way through it.
//!
//! One audit row per target, never one per batch: the trail answers "what was
//! done to this person", and a single row naming thirty subjects could not.

use super::removals::remove_one;
use super::timeouts::{TimeoutError, timeout_one};
use super::{RemoveMemberError, Store, now_ms};
use crate::ids::{SessionId, UserId};

impl Store {
    /// Removes every member in `user_ids`, as one transaction.
    ///
    /// Returns the sessions revoked across the whole batch, for the caller to
    /// close those sockets. Ordering within the returned list is the order the
    /// targets were given, which is the order the audit rows land in too.
    ///
    /// Idempotent per target exactly as the single path is: removing somebody
    /// already removed replaces their row rather than failing, so a retried
    /// request after a dropped response does not half-succeed.
    pub async fn bulk_remove_members(
        &self,
        user_ids: &[UserId],
        removed_by: UserId,
        reason: Option<&str>,
    ) -> Result<Vec<SessionId>, RemoveMemberError> {
        if user_ids.is_empty() {
            return Ok(Vec::new());
        }
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let mut revoked = Vec::new();
        for user_id in user_ids {
            revoked.extend(remove_one(&mut tx, *user_id, removed_by, reason, now).await?);
        }

        tx.commit().await?;
        Ok(revoked)
    }

    /// Times out every member in `user_ids` until `until`, as one transaction.
    ///
    /// `until` is computed once by the caller rather than per target, so every
    /// member in one batch comes back at the same moment. Deriving it inside
    /// the loop would stagger a batch of thirty across however long the
    /// transaction took, which is a difference nobody asked for.
    ///
    /// Returns the members whose timeout actually changed.
    pub async fn bulk_timeout_members(
        &self,
        user_ids: &[UserId],
        until: i64,
        reason: Option<&str>,
        issued_by: UserId,
    ) -> Result<Vec<UserId>, TimeoutError> {
        if user_ids.is_empty() {
            return Ok(Vec::new());
        }
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let mut changed = Vec::new();
        for user_id in user_ids {
            if timeout_one(&mut tx, *user_id, until, reason, issued_by, now).await? {
                changed.push(*user_id);
            }
        }

        tx.commit().await?;
        Ok(changed)
    }
}
