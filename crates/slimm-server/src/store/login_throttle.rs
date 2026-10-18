// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-account, per-caller password guess throttle: a bounded, decaying backoff.
//!
//! The count is keyed by account and the caller's rate-limit address key, so a stranger's
//! guesses only slow that stranger and never keep the real owner out. Past [`FREE_FAILURES`] each further failure doubles
//! a delay capped at [`MAX_DELAY_MS`], and a quiet [`FORGET_AFTER_MS`] forgets the count, so
//! an attacker can slow the owner down but never lock them out for good.

use crate::ids::UserId;
use crate::store::{Store, now_ms};

/// Wrong passwords tolerated back to back before any delay.
pub const FREE_FAILURES: i64 = 10;
const BASE_DELAY_MS: i64 = 15_000;
/// The longest a sign-in can be refused, however many guesses were made.
pub const MAX_DELAY_MS: i64 = 15 * 60_000;
/// A failure this long after the previous one starts the count over. Equal to the longest
/// delay, so a maxed-out lock is forgotten the moment it ends.
pub const FORGET_AFTER_MS: i64 = MAX_DELAY_MS;

/// The delay after the `failures`th consecutive failure.
pub fn delay_ms(failures: i64) -> i64 {
    if failures <= FREE_FAILURES {
        return 0;
    }
    let doublings = (failures - FREE_FAILURES - 1).min(20) as u32;
    (BASE_DELAY_MS << doublings).min(MAX_DELAY_MS)
}

impl Store {
    /// Whether password sign-in for this account from this caller is being refused right now.
    pub async fn login_throttled(&self, user_id: UserId, source: &str) -> anyhow::Result<bool> {
        self.login_throttled_at(user_id, source, now_ms()).await
    }

    pub async fn login_throttled_at(
        &self,
        user_id: UserId,
        source: &str,
        now: i64,
    ) -> anyhow::Result<bool> {
        let locked_until = sqlx::query_scalar!(
            "SELECT locked_until FROM login_throttle WHERE user_id = ? AND source = ?",
            user_id,
            source
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(locked_until.is_some_and(|until| until > now))
    }

    /// Counts a wrong password against the account from this caller and sets the next delay.
    pub async fn record_login_failure(&self, user_id: UserId, source: &str) -> anyhow::Result<()> {
        self.record_login_failure_at(user_id, source, now_ms())
            .await
    }

    pub async fn record_login_failure_at(
        &self,
        user_id: UserId,
        source: &str,
        now: i64,
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        let previous = sqlx::query!(
            "SELECT failures, last_failure_at FROM login_throttle WHERE user_id = ? AND source = ?",
            user_id,
            source
        )
        .fetch_optional(&mut *tx)
        .await?;
        let carried = previous
            .filter(|row| now - row.last_failure_at <= FORGET_AFTER_MS)
            .map_or(0, |row| row.failures);
        let failures = carried + 1;
        let locked_until = now + delay_ms(failures);
        sqlx::query!(
            "INSERT INTO login_throttle (user_id, source, failures, last_failure_at, locked_until)
             VALUES (?, ?, ?, ?, ?)
             ON CONFLICT(user_id, source) DO UPDATE SET
                 failures = excluded.failures,
                 last_failure_at = excluded.last_failure_at,
                 locked_until = excluded.locked_until",
            user_id,
            source,
            failures,
            now,
            locked_until
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Forgets this caller's failures after a correct password; a read first so a
    /// clean sign-in takes no write lock.
    pub async fn clear_login_throttle(&self, user_id: UserId, source: &str) -> anyhow::Result<()> {
        let exists = sqlx::query_scalar!(
            "SELECT 1 AS \"one!: i64\" FROM login_throttle WHERE user_id = ? AND source = ?",
            user_id,
            source
        )
        .fetch_optional(&self.pool)
        .await?
        .is_some();
        if exists {
            sqlx::query!(
                "DELETE FROM login_throttle WHERE user_id = ? AND source = ?",
                user_id,
                source
            )
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    /// Deletes rows whose count would be forgotten anyway.
    pub async fn sweep_login_throttle(&self) -> anyhow::Result<u64> {
        self.sweep_login_throttle_at(now_ms()).await
    }

    pub async fn sweep_login_throttle_at(&self, now: i64) -> anyhow::Result<u64> {
        let cutoff = now - FORGET_AFTER_MS;
        Ok(sqlx::query!(
            "DELETE FROM login_throttle WHERE last_failure_at < ? AND locked_until < ?",
            cutoff,
            now
        )
        .execute(&self.pool)
        .await?
        .rows_affected())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_failures_are_free_then_the_delay_doubles_up_to_the_cap() {
        assert_eq!(delay_ms(FREE_FAILURES), 0);
        assert_eq!(delay_ms(FREE_FAILURES + 1), 15_000);
        assert_eq!(delay_ms(FREE_FAILURES + 2), 30_000);
        assert_eq!(delay_ms(FREE_FAILURES + 3), 60_000);
        assert_eq!(delay_ms(FREE_FAILURES + 40), MAX_DELAY_MS);
        assert_eq!(delay_ms(i64::MAX), MAX_DELAY_MS);
    }
}
