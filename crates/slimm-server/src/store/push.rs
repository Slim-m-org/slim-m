// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Push registration persistence: the device attributes a push relay needs
//! (platform, token, optional VoIP token, and the device's public key), the
//! client-reported lifecycle state used to gate triggering, and the read path
//! that turns a set of recipients into the devices worth pushing to.
//!
//! Every write here is scoped to the device id from the caller's own session,
//! never one taken from the request body, and the underlying UPDATE also
//! checks `user_id`, so a forged or stale device id can only ever fail closed
//! rather than touch a foreign device's registration.

use super::{Store, now_ms};
use crate::ids::{DeviceId, UserId};
use crate::notifications::DEFAULT_PUSH_PREVIEW;

/// Why a push-registration write did not happen.
#[derive(Debug)]
pub enum PushError {
    /// No live device matched the given `(device_id, user_id)` pair, so
    /// nothing was written. This is what makes it impossible for one device
    /// to ever overwrite another device's push registration: the id pair has
    /// to actually belong together.
    NotFound,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for PushError {
    fn from(err: sqlx::Error) -> Self {
        PushError::Internal(err.into())
    }
}

/// One device worth pushing to: its relay identity plus the key push content
/// is sealed to. Not `Debug`, so a token cannot be logged by accident.
pub struct PushTarget {
    pub user_id: UserId,
    pub device_id: DeviceId,
    pub platform: String,
    pub push_token: String,
    /// The PushKit token an iOS ring must use; APNs refuses the ordinary one on the VoIP topic.
    pub voip_push_token: Option<String>,
    pub push_public_key: Vec<u8>,
    pub lifecycle_state: Option<String>,
    pub lifecycle_reported_at: Option<i64>,
    /// Whether this device asked for message content inside the sealed
    /// envelope. Per device rather than per account, because the lock screen
    /// it decides the contents of belongs to one physical device. Never
    /// widens who is pushed at all: it only changes what a device that was
    /// already going to be woken finds inside its own envelope.
    pub include_content: bool,
}

/// What one device is registering: everything about the registration itself,
/// as against the two ids that say whose it is.
///
/// A parameter object rather than five more positional arguments, which would
/// put [`Store::register_push`] past this project's seven-parameter limit and,
/// worse, leave two adjacent `&str`s (`platform` and `push_token`) and two
/// adjacent booleans-or-options that a call site could silently transpose.
/// Not `Debug`: `push_token` and `voip_push_token` must never be logged.
pub struct PushRegistration<'a> {
    /// "ios" or "android"; validated at the route, not here.
    pub platform: &'a str,
    pub push_token: &'a str,
    pub voip_push_token: Option<&'a str>,
    /// The device's X25519 public key, 32 bytes.
    pub push_public_key: &'a [u8],
    /// The member's explicit choice about a sealed preview, saved to the
    /// account. `None` means the client never asked, so the account's own
    /// choice (or `DEFAULT_PUSH_PREVIEW`) applies; a registration can never
    /// reset a choice it did not make.
    pub include_content: Option<bool>,
    /// Set by a client that marks `include_content` as a deliberate toggle.
    /// An unmarked `false` is ignored, because a client that predates the
    /// marker sends `false` whenever the member never toggled; an unmarked
    /// `true` can only be a real opt-in and is always saved.
    pub include_content_chosen: bool,
}

impl Store {
    /// Registers (or replaces) a device's push registration. Always scoped to
    /// `device_id` from the caller's own session and re-checked against
    /// `user_id` in the same `WHERE`, so a caller can never write another
    /// device's registration by supplying a foreign device id.
    ///
    /// A provider push token is a handle to one physical device, not a stable
    /// identity: a reinstall can legitimately hand the same token to a
    /// different account, or to a fresh login's device row for the same
    /// account (every login mints a new device row rather than reusing one).
    /// Whichever row registers the token now is its one true owner, so this
    /// steals it back from any other device row still holding it, in the same
    /// transaction, before writing the caller's own row. Without that, the
    /// token's previous holder would keep receiving pushes meant for its new
    /// owner until something else happened to notice.
    ///
    /// A device id that matches no row of the caller's rolls the whole
    /// transaction back, that steal included. Otherwise a caller could wipe a
    /// stranger's registration by guessing their token and any device id at
    /// all, live or not.
    pub async fn register_push(
        &self,
        user_id: UserId,
        device_id: DeviceId,
        registration: PushRegistration<'_>,
    ) -> Result<(), PushError> {
        let PushRegistration {
            platform,
            push_token,
            voip_push_token,
            push_public_key,
            include_content,
            include_content_chosen,
        } = registration;
        let mut tx = self.begin_write().await?;

        if let Some(choice) = include_content.filter(|&on| on || include_content_chosen) {
            sqlx::query("UPDATE users SET push_include_content = ? WHERE id = ?")
                .bind(choice)
                .bind(user_id)
                .execute(&mut *tx)
                .await?;
        }
        let stored: Option<i64> =
            sqlx::query_scalar("SELECT push_include_content FROM users WHERE id = ?")
                .bind(user_id)
                .fetch_optional(&mut *tx)
                .await?
                .flatten();
        let include_content = stored.map_or(DEFAULT_PUSH_PREVIEW, |v| v != 0);

        sqlx::query!(
            "UPDATE devices
             SET platform = NULL, push_token_ref = NULL, voip_push_token_ref = NULL,
                 push_public_key = NULL, push_include_content = 0
             WHERE id != ? AND push_token_ref = ?",
            device_id,
            push_token
        )
        .execute(&mut *tx)
        .await?;

        let affected = sqlx::query!(
            "UPDATE devices
             SET platform = ?, push_token_ref = ?, voip_push_token_ref = ?, push_public_key = ?,
                 push_include_content = ?
             WHERE id = ? AND user_id = ?",
            platform,
            push_token,
            voip_push_token,
            push_public_key,
            include_content,
            device_id,
            user_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if affected == 0 {
            // Dropping the transaction rolls back the token reassignment
            // above; see the note on this function.
            return Err(PushError::NotFound);
        }
        tx.commit().await?;
        Ok(())
    }

    /// Whether the account's push envelopes carry a preview: the member's
    /// choice, else `DEFAULT_PUSH_PREVIEW`. `None` if the account is gone.
    pub async fn push_preview(&self, user_id: UserId) -> anyhow::Result<Option<bool>> {
        let row: Option<Option<i64>> = sqlx::query_scalar(
            "SELECT push_include_content FROM users WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|choice| choice.map_or(DEFAULT_PUSH_PREVIEW, |v| v != 0)))
    }

    /// Saves the member's explicit choice and re-syncs every device row of the
    /// account. Returns `false` if the account is gone.
    pub async fn set_push_preview(&self, user_id: UserId, enabled: bool) -> anyhow::Result<bool> {
        let mut tx = self.begin_write().await?;
        let affected = sqlx::query(
            "UPDATE users SET push_include_content = ? WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(enabled)
        .bind(user_id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
        sqlx::query("UPDATE devices SET push_include_content = ? WHERE user_id = ?")
            .bind(enabled)
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(affected > 0)
    }

    /// Clears a device's own push registration (the client opting out).
    pub async fn deregister_push(
        &self,
        user_id: UserId,
        device_id: DeviceId,
    ) -> Result<(), PushError> {
        let affected = sqlx::query!(
            "UPDATE devices
             SET platform = NULL, push_token_ref = NULL, voip_push_token_ref = NULL,
                 push_public_key = NULL, push_include_content = 0
             WHERE id = ? AND user_id = ?",
            device_id,
            user_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        if affected == 0 {
            return Err(PushError::NotFound);
        }
        Ok(())
    }

    /// Records the client-reported lifecycle state and when it was reported.
    /// This, not WebSocket presence, is what gates whether a push is sent: a
    /// suspended-but-still-connected socket (iOS backgrounding) is not proof
    /// the app can show a notification.
    pub async fn report_lifecycle(
        &self,
        user_id: UserId,
        device_id: DeviceId,
        state: &str,
    ) -> Result<(), PushError> {
        let now = now_ms();
        let affected = sqlx::query!(
            "UPDATE devices SET lifecycle_state = ?, lifecycle_reported_at = ?
             WHERE id = ? AND user_id = ?",
            state,
            now,
            device_id,
            user_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        if affected == 0 {
            return Err(PushError::NotFound);
        }
        Ok(())
    }

    /// The push-capable devices for a set of users, used to fan a
    /// notification out to every recipient's registered devices. A device
    /// missing either its token or its public key is never returned: it
    /// cannot be sealed to, so it must be skipped rather than sent plaintext.
    /// Neither is a device whose session is gone: a registration otherwise
    /// outlives the session that made it, so without this a signed-out device
    /// (or a stale row left by an earlier login on the same physical device)
    /// would keep receiving push indefinitely.
    ///
    /// The liveness test is [`Store::list_devices`]'s, exactly, and the two
    /// must not drift: this decides what buzzes and that decides what the
    /// owner can see and revoke, so a device live for one and dead for the
    /// other is either a phone notifying an account it can no longer open, or
    /// a row in the settings list that nothing will ever reach.
    /// `tests/it_realtime/device_liveness.rs` is what fails if they diverge.
    pub async fn push_targets(&self, user_ids: &[UserId]) -> anyhow::Result<Vec<PushTarget>> {
        if user_ids.is_empty() {
            return Ok(Vec::new());
        }
        // One batched query, built (no array binding in SQLite), the same shape roles_for_users uses.
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT id, user_id, platform, push_token_ref, voip_push_token_ref, \
                    push_public_key, lifecycle_state, lifecycle_reported_at, \
                    COALESCE((SELECT u.push_include_content FROM users u \
                               WHERE u.id = devices.user_id), ",
        );
        builder.push_bind(DEFAULT_PUSH_PREVIEW);
        builder.push(
            ") AS push_include_content \
             FROM devices \
             WHERE push_token_ref IS NOT NULL \
               AND push_public_key IS NOT NULL AND platform IS NOT NULL \
               AND EXISTS ( \
                     SELECT 1 FROM sessions s \
                     JOIN refresh_tokens r ON r.session_id = s.id \
                      WHERE s.device_id = devices.id \
                        AND s.revoked_at IS NULL \
                        AND r.used_at IS NULL \
                        AND r.revoked_at IS NULL \
                        AND r.expires_at > ",
        );
        builder.push_bind(now_ms());
        builder.push(") AND user_id IN (");
        let mut separated = builder.separated(", ");
        for id in user_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        rows.into_iter()
            .map(|r| {
                Ok(PushTarget {
                    user_id: r.try_get("user_id")?,
                    device_id: r.try_get("id")?,
                    platform: r.try_get("platform")?,
                    push_token: r.try_get("push_token_ref")?,
                    voip_push_token: r.try_get("voip_push_token_ref")?,
                    push_public_key: r.try_get("push_public_key")?,
                    lifecycle_state: r.try_get("lifecycle_state")?,
                    lifecycle_reported_at: r.try_get("lifecycle_reported_at")?,
                    include_content: r.try_get::<i64, _>("push_include_content")? != 0,
                })
            })
            .collect()
    }

    /// Everyone who has at least one device that could actually receive a push
    /// right now: a live session, a token, a key, and a platform.
    ///
    /// This is the candidate set the push trigger starts from, and it exists to
    /// keep that path off an all-users scan. Working the other way round, from
    /// every live user to the ones who can view the channel, costs a full
    /// permission evaluation (several queries) per user on every single
    /// message, whether or not anybody has push set up at all. Starting here
    /// and then filtering by view permission gives the same recipients for the
    /// price of one indexed query plus a check per candidate, and a deployment
    /// where nobody registered for push does no permission work whatsoever.
    pub async fn users_with_push_devices(&self) -> anyhow::Result<Vec<UserId>> {
        let now = now_ms();
        let rows = sqlx::query!(
            r#"SELECT DISTINCT user_id AS "user_id!: UserId"
               FROM devices
               WHERE push_token_ref IS NOT NULL
                 AND push_public_key IS NOT NULL AND platform IS NOT NULL
                 AND EXISTS (
                       SELECT 1 FROM sessions s
                       JOIN refresh_tokens r ON r.session_id = s.id
                        WHERE s.device_id = devices.id
                          AND s.revoked_at IS NULL
                          AND r.used_at IS NULL
                          AND r.revoked_at IS NULL
                          AND r.expires_at > ?
                     )"#,
            now
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| r.user_id).collect())
    }

    /// Clears a device's push registration because the relay reported its
    /// token dead. Scoped to the specific device the caller resolved that
    /// report against (and its owning user), not to the bare token string:
    /// nothing binds a token value to one device on its own (a caller could
    /// misreport, or, before a token is uniquely re-owned on every
    /// [`Self::register_push`], two rows could transiently share one), so a
    /// token alone is never enough to identify whose registration to touch.
    /// The token is still checked too: if the device already re-registered
    /// with a fresh one before this stale report arrived, `push_token_ref` no
    /// longer matches, the `UPDATE` touches no rows, and the fresh
    /// registration is left alone.
    pub async fn clear_push_registration(
        &self,
        user_id: UserId,
        device_id: DeviceId,
        push_token: &str,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE devices
             SET platform = NULL, push_token_ref = NULL, voip_push_token_ref = NULL,
                 push_public_key = NULL, push_include_content = 0
             WHERE id = ? AND user_id = ? AND push_token_ref = ?",
            device_id,
            user_id,
            push_token
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Clears only a device's VoIP token after the relay reported it dead, so its ordinary
    /// token keeps carrying message pushes.
    pub async fn clear_voip_push_token(
        &self,
        user_id: UserId,
        device_id: DeviceId,
        voip_push_token: &str,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE devices SET voip_push_token_ref = NULL
             WHERE id = ? AND user_id = ? AND voip_push_token_ref = ?",
            device_id,
            user_id,
            voip_push_token
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
