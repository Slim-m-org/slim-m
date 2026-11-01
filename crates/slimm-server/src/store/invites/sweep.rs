// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::Store;
use crate::store::now_ms;

/// How long a dead invite stays listed before the sweep drops it.
const DEAD_INVITE_GRACE_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// Rows removed per pass, so one pass never holds the writer for long.
const SWEEP_BATCH: i64 = 5000;

impl Store {
    /// Deletes invites that were revoked, expired or spent more than the grace
    /// window ago, returning how many. A spent code counts from its last
    /// redemption so a retried redeem right after the spend still finds it.
    pub async fn sweep_dead_invites(&self) -> anyhow::Result<u64> {
        self.sweep_dead_invites_at(now_ms()).await
    }

    pub async fn sweep_dead_invites_at(&self, now: i64) -> anyhow::Result<u64> {
        let cutoff = now - DEAD_INVITE_GRACE_MS;
        Ok(sqlx::query!(
            "DELETE FROM invites WHERE code IN (
                SELECT i.code FROM invites i
                WHERE (i.revoked_at IS NOT NULL AND i.revoked_at < ?1)
                   OR (i.expires_at IS NOT NULL AND i.expires_at < ?1)
                   OR (i.max_uses IS NOT NULL AND i.uses >= i.max_uses
                       AND i.created_at < ?1
                       AND COALESCE((SELECT MAX(r.redeemed_at) FROM invite_redemptions r
                                     WHERE r.code = i.code), 0) < ?1)
                LIMIT ?2)",
            cutoff,
            SWEEP_BATCH
        )
        .execute(&self.pool)
        .await?
        .rows_affected())
    }
}
