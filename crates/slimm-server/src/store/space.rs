// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deployment-wide settings an admin changes at runtime.
//!
//! One row, read on registration and written from the Space settings screen.
//! See `migrations/0018_space_settings.sql` for why the default is `invite`.

use anyhow::Context;
use sqlx::SqliteExecutor;

use super::Store;
use super::now_ms;
use super::totp::TotpPolicy;

/// The highest resolution `ScreenShareQuality.crisp` already asks a desktop
/// to publish (see `client/packages/rtc/lib/src/screen_share.dart`). The
/// default, and what every deployment that predates this setting keeps on
/// upgrade, so behaviour is unchanged until an admin lowers it.
pub const DEFAULT_SCREEN_SHARE_MAX_HEIGHT: i64 = 2160;

/// The range a deployment may set its screen-share height ceiling to
/// (`Store::set_screen_share_max_height`). The floor keeps a share legible;
/// the ceiling is the same [`DEFAULT_SCREEN_SHARE_MAX_HEIGHT`] a deployment
/// already allows today, so raising it further would only ever loosen
/// behaviour nothing here has ever enforced. Enforced in Rust, not as a
/// CHECK, so the range can move without a migration - the same split
/// `MAX_MESSAGE_RETENTION_DAYS` and `MAX_CANVAS_OBJECT_CAP` use.
pub const MIN_SCREEN_SHARE_MAX_HEIGHT: i64 = 360;
pub const MAX_SCREEN_SHARE_MAX_HEIGHT: i64 = DEFAULT_SCREEN_SHARE_MAX_HEIGHT;

/// Who may create an account on this deployment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JoinPolicy {
    /// A valid invite code is required. The default, and what every
    /// deployment that predates this setting keeps on upgrade.
    Invite,
    /// Anyone who can reach the server may register.
    Open,
}

impl JoinPolicy {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Invite => "invite",
            Self::Open => "open",
        }
    }

    /// Unrecognised text reads as [`JoinPolicy::Invite`] rather than as open.
    /// The CHECK constraint makes that unreachable through this API, and the
    /// fallback still has to be the closed one: a row somehow holding junk
    /// must not be the reason a Space is open to the internet.
    ///
    /// Deliberately not [`std::str::FromStr`]: that returns a `Result`, and
    /// this must not have a failing branch a caller could unwrap into a panic.
    pub fn parse(value: &str) -> Self {
        match value {
            "open" => Self::Open,
            _ => Self::Invite,
        }
    }
}

/// Read inside a caller's transaction, so registration sees a policy change
/// that lands concurrently rather than a snapshot from before it.
pub(super) async fn read_join_policy<'e, E>(executor: E) -> anyhow::Result<JoinPolicy>
where
    E: SqliteExecutor<'e>,
{
    let row = sqlx::query_scalar!(
        r#"SELECT join_policy AS "p!: String" FROM space_settings WHERE id = 1"#
    )
    .fetch_optional(executor)
    .await
    .context("read join policy")?;
    Ok(row
        .as_deref()
        .map(JoinPolicy::parse)
        .unwrap_or(JoinPolicy::Invite))
}

/// The effective per-channel canvas object cap, read inside a caller's
/// transaction so an enforcement count sees a cap change that lands
/// concurrently rather than a snapshot from before it - the same reasoning
/// [`read_join_policy`] gives. Falls back to `MAX_OBJECTS_PER_CHANNEL` for a
/// row written before this column existed.
pub(super) async fn read_canvas_object_cap<'e, E>(executor: E) -> anyhow::Result<i64>
where
    E: SqliteExecutor<'e>,
{
    let cap = sqlx::query_scalar!(
        r#"SELECT canvas_object_cap AS "c!: i64" FROM space_settings WHERE id = 1"#
    )
    .fetch_optional(executor)
    .await
    .context("read canvas object cap")?;
    Ok(cap.unwrap_or(super::MAX_OBJECTS_PER_CHANNEL))
}

/// The effective screen-share height ceiling, read inside a caller's
/// transaction for the same reason [`read_canvas_object_cap`] is. Falls back
/// to [`DEFAULT_SCREEN_SHARE_MAX_HEIGHT`] for a row written before this
/// column existed.
pub(super) async fn read_screen_share_max_height<'e, E>(executor: E) -> anyhow::Result<i64>
where
    E: SqliteExecutor<'e>,
{
    let height = sqlx::query_scalar!(
        r#"SELECT screen_share_max_height AS "h!: i64" FROM space_settings WHERE id = 1"#
    )
    .fetch_optional(executor)
    .await
    .context("read screen share max height")?;
    Ok(height.unwrap_or(DEFAULT_SCREEN_SHARE_MAX_HEIGHT))
}

impl Store {
    pub async fn join_policy(&self) -> anyhow::Result<JoinPolicy> {
        read_join_policy(&self.pool).await
    }

    /// The per-channel canvas object cap in force for this deployment.
    pub async fn canvas_object_cap(&self) -> anyhow::Result<i64> {
        read_canvas_object_cap(&self.pool).await
    }

    /// The screen-share height ceiling in force for this deployment. A client
    /// reads this and caps its own capture/publish parameters before starting
    /// a share; there is no server-side enforcement.
    pub async fn screen_share_max_height(&self) -> anyhow::Result<i64> {
        read_screen_share_max_height(&self.pool).await
    }

    /// Whether members' microphones default to the stronger noise
    /// suppression; applied on each member's own device.
    pub async fn strong_noise_suppression(&self) -> anyhow::Result<bool> {
        let enabled = sqlx::query_scalar!(
            r#"SELECT strong_noise_suppression AS "v!: bool" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read strong noise suppression")?;
        Ok(enabled.unwrap_or(false))
    }

    pub async fn set_strong_noise_suppression(&self, enabled: bool) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET strong_noise_suppression = ?, updated_at = ? WHERE id = 1",
            enabled,
            now
        )
        .execute(&self.pool)
        .await
        .context("set strong noise suppression")?;
        Ok(())
    }

    /// Sets the screen-share height ceiling. The caller is responsible for
    /// range-checking against `MIN_SCREEN_SHARE_MAX_HEIGHT` and
    /// `MAX_SCREEN_SHARE_MAX_HEIGHT`; the DB CHECK only guards the `>= 1`
    /// invariant.
    pub async fn set_screen_share_max_height(&self, height: i64) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET screen_share_max_height = ?, updated_at = ? WHERE id = 1",
            height,
            now
        )
        .execute(&self.pool)
        .await
        .context("set screen share max height")?;
        Ok(())
    }

    /// Sets the per-channel canvas object cap. The caller is responsible for
    /// range-checking against `MIN_CANVAS_OBJECT_CAP` and
    /// `MAX_CANVAS_OBJECT_CAP`; the DB CHECK only guards the `>= 1` invariant.
    pub async fn set_canvas_object_cap(&self, cap: i64) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET canvas_object_cap = ?, updated_at = ? WHERE id = 1",
            cap,
            now
        )
        .execute(&self.pool)
        .await
        .context("set canvas object cap")?;
        Ok(())
    }

    /// This deployment's second-factor policy. Read on every enrolment and
    /// reported to the client so a screen can say what the operator chose.
    ///
    /// An unrecognised stored value falls back to `optional` rather than
    /// failing the request: a policy nobody can parse must not be read as
    /// "off", which would quietly stop new enrolments.
    pub async fn totp_policy(&self) -> anyhow::Result<TotpPolicy> {
        let value = sqlx::query_scalar!(
            r#"SELECT totp_policy AS "p!: String" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read totp policy")?;
        Ok(value
            .as_deref()
            .and_then(TotpPolicy::parse)
            .unwrap_or(TotpPolicy::Optional))
    }

    pub async fn set_totp_policy(&self, policy: TotpPolicy) -> anyhow::Result<()> {
        let now = now_ms();
        let value = policy.as_str();
        sqlx::query!(
            "UPDATE space_settings SET totp_policy = ?, updated_at = ? WHERE id = 1",
            value,
            now
        )
        .execute(&self.pool)
        .await
        .context("set totp policy")?;
        Ok(())
    }

    /// The admin's per-attachment ceiling in bytes, or 0 when none is set and
    /// the operator's `SLIMM_ATTACHMENT_MAX_BYTES` alone applies.
    pub async fn attachment_max_bytes(&self) -> anyhow::Result<u64> {
        let bytes = sqlx::query_scalar!(
            r#"SELECT attachment_max_bytes AS "b!: i64" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read attachment max bytes")?;
        Ok(bytes.unwrap_or(0).max(0) as u64)
    }

    /// The caller range-checks against the operator's ceiling; the DB CHECK
    /// only guards `>= 0`.
    pub async fn set_attachment_max_bytes(&self, bytes: u64) -> anyhow::Result<()> {
        let now = now_ms();
        let bytes = i64::try_from(bytes).context("attachment max bytes overflows i64")?;
        sqlx::query!(
            "UPDATE space_settings SET attachment_max_bytes = ?, updated_at = ? WHERE id = 1",
            bytes,
            now
        )
        .execute(&self.pool)
        .await
        .context("set attachment max bytes")?;
        Ok(())
    }

    pub async fn set_join_policy(&self, policy: JoinPolicy) -> anyhow::Result<()> {
        let now = now_ms();
        let value = policy.as_str();
        sqlx::query!(
            "UPDATE space_settings SET join_policy = ?, updated_at = ? WHERE id = 1",
            value,
            now
        )
        .execute(&self.pool)
        .await
        .context("set join policy")?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::JoinPolicy;

    /// The security-critical branch. The CHECK constraint makes junk
    /// unreachable through the write path, so this fallback is the only thing
    /// between a row that somehow holds garbage and a Space open to the
    /// internet: anything unrecognised must read closed, never Open.
    #[test]
    fn unrecognised_text_reads_as_invite_never_open() {
        for junk in ["", "OPEN", "Open", "public", "invite ", "open\n", "yes"] {
            assert_eq!(
                JoinPolicy::parse(junk),
                JoinPolicy::Invite,
                "{junk:?} must fail closed"
            );
        }
    }

    #[test]
    fn exactly_open_reads_as_open() {
        assert_eq!(JoinPolicy::parse("open"), JoinPolicy::Open);
        assert_eq!(JoinPolicy::parse("invite"), JoinPolicy::Invite);
    }

    /// The two halves cannot drift: whatever `as_str` writes, `parse` reads back.
    #[test]
    fn as_str_round_trips_through_parse() {
        for policy in [JoinPolicy::Invite, JoinPolicy::Open] {
            assert_eq!(JoinPolicy::parse(policy.as_str()), policy);
        }
    }
}
