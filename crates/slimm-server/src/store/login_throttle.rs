// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Password guess throttle: a bounded, decaying backoff at two levels.
//!
//! The first count is keyed by account and the caller's rate-limit address key, so a stranger's
//! guesses only slow that stranger and never keep the real owner out. Past [`FREE_FAILURES`] each
//! further failure doubles a delay capped at [`MAX_DELAY_MS`].
//!
//! A second count per account, across every address, bounds distributed guessing: many addresses
//! each stay under their own budget, but together they spend [`ACCOUNT_FREE_FAILURES`] and then
//! earn a shorter delay capped at [`ACCOUNT_MAX_DELAY_MS`]. It is a delay and not a lock, it is
//! never extended by refused attempts, and a quiet [`FORGET_AFTER_MS`] or one correct password
//! forgets it, so an attacker can slow the owner down but never lock them out for good.

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

/// Wrong passwords tolerated across all addresses before the account itself slows down. Well
/// above [`FREE_FAILURES`], so a few honest typos from several devices never reach it.
pub const ACCOUNT_FREE_FAILURES: i64 = 30;
/// The longest the account-wide delay can hold a sign-in, short so the owner's wait stays small.
pub const ACCOUNT_MAX_DELAY_MS: i64 = 5 * 60_000;
/// The `source` of the account-wide row; no limiter key starts without `ip:` or `u:`.
const ACCOUNT_SOURCE: &str = "*";

/// The delay after the `failures`th consecutive failure from one address.
pub fn delay_ms(failures: i64) -> i64 {
    backoff_ms(failures, FREE_FAILURES, MAX_DELAY_MS)
}

/// The delay after the `failures`th consecutive failure across all addresses.
pub fn account_delay_ms(failures: i64) -> i64 {
    backoff_ms(failures, ACCOUNT_FREE_FAILURES, ACCOUNT_MAX_DELAY_MS)
}

fn backoff_ms(failures: i64, free: i64, max_delay: i64) -> i64 {
    if failures <= free {
        return 0;
    }
    let doublings = (failures - free - 1).min(20) as u32;
    (BASE_DELAY_MS << doublings).min(max_delay)
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
        let locked = sqlx::query_scalar!(
            "SELECT 1 AS \"one!: i64\" FROM login_throttle
             WHERE user_id = ? AND source IN (?, ?) AND locked_until > ?",
            user_id,
            source,
            ACCOUNT_SOURCE,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(locked.is_some())
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
        bump(&mut tx, user_id, source, now, delay_ms).await?;
        bump(&mut tx, user_id, ACCOUNT_SOURCE, now, account_delay_ms).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Forgets this caller's failures and the account-wide count after a correct password, so
    /// the owner's own sign-in ends whatever guessing slowed them. A read first so a clean
    /// sign-in takes no write lock.
    pub async fn clear_login_throttle(&self, user_id: UserId, source: &str) -> anyhow::Result<()> {
        let exists = sqlx::query_scalar!(
            "SELECT 1 AS \"one!: i64\" FROM login_throttle WHERE user_id = ? AND source IN (?, ?)",
            user_id,
            source,
            ACCOUNT_SOURCE
        )
        .fetch_optional(&self.pool)
        .await?
        .is_some();
        if exists {
            sqlx::query!(
                "DELETE FROM login_throttle WHERE user_id = ? AND source IN (?, ?)",
                user_id,
                source,
                ACCOUNT_SOURCE
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

/// Counts one more failure on the `(user_id, source)` row and sets its next delay.
async fn bump(
    tx: &mut sqlx::SqliteConnection,
    user_id: UserId,
    source: &str,
    now: i64,
    delay: fn(i64) -> i64,
) -> anyhow::Result<()> {
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
    let locked_until = now + delay(failures);
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
    Ok(())
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

    #[test]
    fn the_account_wide_budget_is_larger_and_its_delay_shorter() {
        assert_eq!(account_delay_ms(ACCOUNT_FREE_FAILURES), 0);
        assert_eq!(account_delay_ms(ACCOUNT_FREE_FAILURES + 1), 15_000);
        assert_eq!(account_delay_ms(i64::MAX), ACCOUNT_MAX_DELAY_MS);
        const { assert!(ACCOUNT_FREE_FAILURES > FREE_FAILURES && ACCOUNT_MAX_DELAY_MS < MAX_DELAY_MS) };
    }
}
