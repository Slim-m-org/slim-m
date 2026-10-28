// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who claimed the deployment and whether they have finished or dismissed the
//! first-run setup the client offers them once.

use anyhow::Context;

use super::{Store, now_ms};
use crate::ids::UserId;

/// `claimed_by` is `None` on a deployment claimed before the column existed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpaceSetup {
    pub claimed_by: Option<UserId>,
    pub done_at: Option<i64>,
}

impl Store {
    pub async fn space_setup(&self) -> anyhow::Result<SpaceSetup> {
        let row = sqlx::query!(
            r#"SELECT setup_claimed_by AS "claimed_by: UserId", setup_done_at
               FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read space setup")?;
        Ok(row.map_or(
            SpaceSetup {
                claimed_by: None,
                done_at: None,
            },
            |r| SpaceSetup {
                claimed_by: r.claimed_by,
                done_at: r.setup_done_at,
            },
        ))
    }

    /// Keeps the first completion time, so finishing twice changes nothing.
    pub async fn complete_space_setup(&self) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET setup_done_at = COALESCE(setup_done_at, ?) WHERE id = 1",
            now
        )
        .execute(&self.pool)
        .await
        .context("complete space setup")?;
        Ok(())
    }
}
