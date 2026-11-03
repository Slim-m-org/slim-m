// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin uplink test's results: a short history, newest first.

use anyhow::Context;

use super::Store;

/// Results kept; older ones are dropped when a new one lands.
pub const UPLINK_HISTORY_LEN: i64 = 10;

/// One finished measurement.
#[derive(Debug, Clone, PartialEq)]
pub struct UplinkTest {
    pub id: i64,
    pub measured_at: i64,
    pub mbit_per_s: f64,
    pub bytes: i64,
    pub duration_ms: i64,
}

impl Store {
    /// The kept results, newest first.
    pub async fn uplink_tests(&self) -> anyhow::Result<Vec<UplinkTest>> {
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: i64", measured_at, mbit_per_s, bytes, duration_ms
               FROM uplink_tests ORDER BY id DESC LIMIT ?"#,
            UPLINK_HISTORY_LEN
        )
        .fetch_all(&self.pool)
        .await
        .context("read uplink tests")?;
        Ok(rows
            .into_iter()
            .map(|r| UplinkTest {
                id: r.id,
                measured_at: r.measured_at,
                mbit_per_s: r.mbit_per_s,
                bytes: r.bytes,
                duration_ms: r.duration_ms,
            })
            .collect())
    }

    /// Stores a result and drops everything past [`UPLINK_HISTORY_LEN`].
    pub async fn record_uplink_test(
        &self,
        mbit_per_s: f64,
        bytes: i64,
        duration_ms: i64,
    ) -> anyhow::Result<UplinkTest> {
        let measured_at = super::now_ms();
        let mut tx = self.begin_write().await?;
        let id = sqlx::query!(
            "INSERT INTO uplink_tests (measured_at, mbit_per_s, bytes, duration_ms)
             VALUES (?, ?, ?, ?)",
            measured_at,
            mbit_per_s,
            bytes,
            duration_ms
        )
        .execute(&mut *tx)
        .await
        .context("insert uplink test")?
        .last_insert_rowid();
        sqlx::query!(
            "DELETE FROM uplink_tests WHERE id NOT IN
             (SELECT id FROM uplink_tests ORDER BY id DESC LIMIT ?)",
            UPLINK_HISTORY_LEN
        )
        .execute(&mut *tx)
        .await
        .context("prune uplink tests")?;
        tx.commit().await.context("commit uplink test")?;
        Ok(UplinkTest {
            id,
            measured_at,
            mbit_per_s,
            bytes,
            duration_ms,
        })
    }

    /// Whether any voice session is open, which an uplink test must not disturb.
    pub async fn any_voice_session_open(&self) -> anyhow::Result<bool> {
        let open = sqlx::query_scalar!(
            r#"SELECT EXISTS(SELECT 1 FROM voice_sessions WHERE left_at IS NULL) AS "open!: bool""#
        )
        .fetch_one(&self.pool)
        .await
        .context("check open voice sessions")?;
        Ok(open)
    }
}
