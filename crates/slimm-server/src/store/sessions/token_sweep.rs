// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reclaiming token rows that are far enough past their expiry to be useless.

use super::REFRESH_TTL_MS;
use crate::store::{Store, now_ms};

/// How long past its own expiry a refresh token is kept before being swept.
///
/// Not zero, and not tunable down casually: reuse detection works by finding
/// the spent row and noticing `used_at` is set (see [`Store::rotate_refresh`]).
/// Delete the row and a replayed token stops being distinguishable from one
/// that never existed, so the family is denied softly instead of being revoked
/// as leaked. Keeping a full extra `REFRESH_TTL_MS` past expiry means anything
/// still worth detecting is still there: by then the token has been unusable
/// for a month and the attacker has had nothing to gain from it for as long.
const REFRESH_SWEEP_GRACE_MS: i64 = REFRESH_TTL_MS;

/// How long past expiry a spent or stale connect ticket is kept. Single use is
/// enforced by `used_at` inside the 30-second window, so nothing after that
/// window depends on the row existing; the hour is slack for clock skew.
const TICKET_SWEEP_GRACE_MS: i64 = 60 * 60 * 1000;

/// How long past expiry an access token row is kept. Authorization already
/// checks `expires_at`, so an expired row grants nothing; the day is slack.
const ACCESS_SWEEP_GRACE_MS: i64 = 24 * 60 * 60 * 1000;

/// How many rows one delete statement removes.
///
/// Bounded so no single statement takes the write lock for an unbounded
/// stretch on a deployment that has gone a long time without a sweep; the
/// sweep loops batch after batch instead, yielding between them.
const SWEEP_BATCH: i64 = 5_000;

/// Batches per table per pass: a million rows, far past any real backlog, so
/// one pass drains it while a runaway table still cannot pin the sweep.
const MAX_BATCHES_PER_PASS: u32 = 200;

/// Runs `batch` until it removes fewer than a full batch, returning the total.
async fn drain<F, Fut>(mut batch: F) -> Result<u64, sqlx::Error>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<u64, sqlx::Error>>,
{
    let mut total = 0;
    for _ in 0..MAX_BATCHES_PER_PASS {
        let removed = batch().await?;
        total += removed;
        if removed < SWEEP_BATCH as u64 {
            break;
        }
        tokio::task::yield_now().await;
    }
    Ok(total)
}

/// What one sweep removed, so the caller can log something meaningful and a
/// test can assert on it.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SweptTokens {
    pub access_tokens: u64,
    pub refresh_tokens: u64,
    pub ws_tickets: u64,
}

impl SweptTokens {
    pub fn total(self) -> u64 {
        self.access_tokens + self.refresh_tokens + self.ws_tickets
    }
}

impl Store {
    /// Deletes token rows that are far enough past their expiry to be useless.
    ///
    /// Every sign-in writes an access token and a refresh token, every rotation
    /// writes another refresh token, and every socket connect writes a ticket.
    /// Nothing deleted any of them except the targeted revocation paths, so all
    /// three tables grew for the life of a deployment and never shrank, taking
    /// the indexes over them along for the ride.
    ///
    /// Each grace window is chosen so nothing that still means something is
    /// removed; see the constants for why, particularly
    /// [`REFRESH_SWEEP_GRACE_MS`], which reuse detection depends on.
    ///
    /// The three deletes are separate statements rather than one transaction:
    /// the tables are independent, and holding the write lock across all three
    /// buys nothing while making the pause longer.
    pub async fn sweep_expired_tokens(&self) -> anyhow::Result<SweptTokens> {
        let now = now_ms();
        let access_cutoff = now - ACCESS_SWEEP_GRACE_MS;
        let refresh_cutoff = now - REFRESH_SWEEP_GRACE_MS;
        let ticket_cutoff = now - TICKET_SWEEP_GRACE_MS;

        // Separate statements, not one transaction; see the note on this function.
        let access_tokens = drain(|| async {
            sqlx::query!(
                "DELETE FROM access_tokens WHERE rowid IN
                 (SELECT rowid FROM access_tokens WHERE expires_at < ? LIMIT ?)",
                access_cutoff,
                SWEEP_BATCH
            )
            .execute(&self.pool)
            .await
            .map(|done| done.rows_affected())
        })
        .await?;

        let refresh_tokens = drain(|| async {
            sqlx::query!(
                "DELETE FROM refresh_tokens WHERE rowid IN
                 (SELECT rowid FROM refresh_tokens WHERE expires_at < ? LIMIT ?)",
                refresh_cutoff,
                SWEEP_BATCH
            )
            .execute(&self.pool)
            .await
            .map(|done| done.rows_affected())
        })
        .await?;

        let ws_tickets = drain(|| async {
            sqlx::query!(
                "DELETE FROM ws_tickets WHERE rowid IN
                 (SELECT rowid FROM ws_tickets WHERE expires_at < ? LIMIT ?)",
                ticket_cutoff,
                SWEEP_BATCH
            )
            .execute(&self.pool)
            .await
            .map(|done| done.rows_affected())
        })
        .await?;

        Ok(SweptTokens {
            access_tokens,
            refresh_tokens,
            ws_tickets,
        })
    }
}
