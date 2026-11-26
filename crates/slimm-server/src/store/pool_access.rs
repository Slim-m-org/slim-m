// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Connection-level access to the SQLite pool: the liveness ping, pool
//! occupancy, and the two transaction openers every write or snapshot read uses.

use super::Store;

/// A snapshot of [`Store::pool_stats`]: how many of the pool's connections
/// are open at all, and how many of those are currently checked out.
#[derive(Debug, Clone, Copy)]
pub struct PoolStats {
    pub max: u32,
    pub size: u32,
    pub in_use: u32,
}

impl Store {
    /// Confirms the database answers a trivial query. Backs the liveness probe.
    pub async fn ping(&self) -> anyhow::Result<()> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }

    /// Live occupancy of the shared SQLite pool, for `/metrics`'s pool
    /// gauges: reads and non-transactional writes share these eight connections,
    /// so how many are checked out is the most direct signal of contention
    /// this server has. `max` is read off the pool's own configuration
    /// rather than duplicated as a constant, so it can never drift from
    /// what `db::connect` actually set.
    pub fn pool_stats(&self) -> PoolStats {
        let size = self.pool.size();
        let idle = u32::try_from(self.pool.num_idle()).unwrap_or(size);
        PoolStats {
            max: self.pool.options().get_max_connections(),
            size,
            in_use: size.saturating_sub(idle),
        }
    }

    /// Opens a transaction that takes SQLite's write lock immediately.
    ///
    /// Only one caller at a time waits for the lock, holding a connection; the
    /// rest queue on [`Store::write_gate`] without one, so a burst of writers
    /// cannot take every connection from the readers. A plain `BEGIN` is
    /// deferred: it takes a read snapshot on its first statement and only tries
    /// for the write lock later. If another connection took that lock in
    /// between, the upgrade cannot wait, because two readers both waiting to
    /// become writers would deadlock, so SQLite returns SQLITE_BUSY at once and
    /// `busy_timeout` never comes into it.
    ///
    /// Any transaction whose first statement is a write already avoids this by
    /// construction, which is what most of the store does deliberately (see
    /// [`Store::rotate_refresh`]). Use this for the ones that genuinely have to
    /// read before they decide what to write.
    pub(crate) async fn begin_write(
        &self,
    ) -> Result<sqlx::Transaction<'_, sqlx::Sqlite>, sqlx::Error> {
        let _turn = tokio::time::timeout(crate::db::ACQUIRE_TIMEOUT, self.write_gate.acquire())
            .await
            .map_err(|_| sqlx::Error::PoolTimedOut)?
            .map_err(|_| sqlx::Error::PoolClosed)?;
        self.pool.begin_with("BEGIN IMMEDIATE").await
    }

    /// Opens a transaction that only reads, for a consistent snapshot across
    /// several statements.
    ///
    /// The deferred `BEGIN` is right here and only here: nothing in it ever
    /// asks for the write lock, so there is no upgrade to be refused. A
    /// transaction that writes anything takes [`Store::begin_write`], even
    /// when its first statement is itself a write, so that adding a read in
    /// front of it later cannot turn a concurrent request into a 500.
    pub(crate) async fn begin_read(
        &self,
    ) -> Result<sqlx::Transaction<'_, sqlx::Sqlite>, sqlx::Error> {
        self.pool.begin().await
    }
}
