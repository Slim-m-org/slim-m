// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deciding whether a sign-in is worth telling the account about.

use super::{Store, now_ms};
use crate::ids::{DeviceId, UserId};

impl Store {
    /// Whether the sign-in that just minted `device_id` should alert the
    /// account's other devices.
    ///
    /// The name and client kind a login reports are chosen by whoever signs in, so they never
    /// make a sign-in familiar. Only a repeat install is known, and that is decided before this
    /// runs (see `http::sign_in_alert`). The first device of an account has no one to tell, so
    /// it needs another *live* device to alert. The liveness clause matches
    /// [`Store::list_devices`], so the alert never targets a device the owner can no longer see
    /// or sign out.
    pub async fn is_unfamiliar_sign_in(
        &self,
        user_id: UserId,
        device_id: DeviceId,
    ) -> anyhow::Result<bool> {
        let now = now_ms();
        let unfamiliar = sqlx::query_scalar!(
            r#"SELECT (
                 EXISTS (
                   SELECT 1 FROM devices d
                   WHERE d.user_id = ? AND d.id != ?
                     AND EXISTS (
                       SELECT 1 FROM sessions s
                       JOIN refresh_tokens r ON r.session_id = s.id
                       WHERE s.device_id = d.id
                         AND s.revoked_at IS NULL
                         AND r.used_at IS NULL
                         AND r.revoked_at IS NULL
                         AND r.expires_at > ?
                     )
                 )
               ) AS "unfamiliar!: bool""#,
            user_id,
            device_id,
            now
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(unfamiliar)
    }
}
