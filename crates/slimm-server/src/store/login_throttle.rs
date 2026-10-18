// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-account password guess throttle: a bounded, decaying backoff.
//!
//! The per-address limiter does not slow a guesser who rotates addresses, so the account
//! itself counts failed password checks. Past [`FREE_FAILURES`] each further failure doubles
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
    /// Whether password sign-in for this account is being refused right now.
    pub async fn login_throttled(&self, user_id: UserId) -> anyhow::Result<bool> {
        self.login_throttled_at(user_id, now_ms()).await
    }

    pub async fn login_throttled_at(&self, user_id: UserId, now: i64) -> anyhow::Result<bool> {
        let locked_until = sqlx::query_scalar!(
            "SELECT locked_until FROM login_throttle WHERE user_id = ?",
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(locked_until.is_some_and(|until| until > now))
    }

    /// Counts a wrong password against the account and sets the next delay.
    pub async fn record_login_failure(&self, user_id: UserId) -> anyhow::Result<()> {
        self.record_login_failure_at(user_id, now_ms()).await
    }

    pub async fn record_login_failure_at(&self, user_id: UserId, now: i64) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        let previous = sqlx::query!(
            "SELECT failures, last_failure_at FROM login_throttle WHERE user_id = ?",
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let carried = previous
            .filter(|row| now - row.last_failure_at <= FORGET_AFTER_MS)
            .map_or(0, |row| row.failures);
        let failures = carried + 1;
        let locked_until = now + delay_ms(failures);
        sqlx::query!(
            "INSERT INTO login_throttle (user_id, failures, last_failure_at, locked_until)
             VALUES (?, ?, ?, ?)
             ON CONFLICT(user_id) DO UPDATE SET
                 failures = excluded.failures,
                 last_failure_at = excluded.last_failure_at,
                 locked_until = excluded.locked_until",
            user_id,
            failures,
            now,
            locked_until
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Forgets the account's failures after a correct password.
    pub async fn clear_login_throttle(&self, user_id: UserId) -> anyhow::Result<()> {
        sqlx::query!("DELETE FROM login_throttle WHERE user_id = ?", user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
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
