// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Refresh tokens that a device removal or an account deletion took with it.
//!
//! Both delete the device rows, and the cascade through `sessions` deletes the
//! refresh rows too, so a tab still holding one of those tokens used to be
//! refused as `unknown`, the same as a token this server never issued. The
//! hashes are kept here, with why they went, until the sweep would have taken
//! the rows anyway, so that refusal names its real cause.

use sqlx::SqliteConnection;

use super::refresh_rotation::RefreshDenial;
use crate::ids::{DeviceId, UserId};

/// Why a token's rows went before it expired.
#[derive(Debug, Clone, Copy)]
pub(super) enum DropCause {
    DeviceRemoved,
    AccountDeleted,
}

impl DropCause {
    fn code(self) -> &'static str {
        match self {
            DropCause::DeviceRemoved => "device_removed",
            DropCause::AccountDeleted => "account_deleted",
        }
    }
}

/// Keeps the hash of every unretired refresh token on `user_id`'s sessions,
/// only those on `device` when it is given, before a delete cascades them away.
pub(super) async fn keep_dropped_refresh_tokens(
    conn: &mut SqliteConnection,
    user_id: UserId,
    device: Option<DeviceId>,
    cause: DropCause,
) -> anyhow::Result<()> {
    let code = cause.code();
    sqlx::query!(
        "INSERT OR IGNORE INTO dropped_refresh_tokens (token_hash, cause, expires_at)
         SELECT r.token_hash, ?, r.expires_at
           FROM refresh_tokens r JOIN sessions s ON s.id = r.session_id
          WHERE s.user_id = ? AND (? IS NULL OR s.device_id = ?) AND r.retired_at IS NULL",
        code,
        user_id,
        device,
        device
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// Why `token_hash` was dropped, or `None` when it never was.
pub(super) async fn dropped_refresh_denial(
    conn: &mut SqliteConnection,
    token_hash: &str,
) -> anyhow::Result<Option<RefreshDenial>> {
    let cause = sqlx::query_scalar!(
        "SELECT cause FROM dropped_refresh_tokens WHERE token_hash = ?",
        token_hash
    )
    .fetch_optional(conn)
    .await?;
    Ok(cause.map(|cause| match cause.as_str() {
        "device_removed" => RefreshDenial::DeviceRemoved,
        "account_deleted" => RefreshDenial::AccountDeleted,
        _ => RefreshDenial::Unknown,
    }))
}
