// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The device list and blocking.
//!
//! This is the safety surface the owner chose, minus the report queue (split
//! into `reports.rs` to stay under the file review budget): manual reports
//! reviewed by a person, and per-user blocking. There is no automated content
//! or media scanning anywhere, by decision, so nothing here inspects message
//! content.

use std::collections::HashSet;

use sqlx::QueryBuilder;

use super::sessions::revoke_session_rows;
use super::{Store, now_ms};
use crate::ids::{DeviceId, SessionId, UserId};

/// A device on the account, for the settings device list.
#[derive(Debug, Clone)]
pub struct Device {
    pub id: DeviceId,
    pub name: String,
    pub created_at: i64,
    pub last_seen_at: Option<i64>,
    /// A coarse client kind ("ios", "android", "desktop", "web"), or `None`
    /// for a session opened before migration 0076. Named by the client at
    /// sign-in, the same "the client says who it is" trust `name` already
    /// carries.
    pub client_kind: Option<String>,
    /// The app version that opened this session, or `None` for the same
    /// reason as `client_kind`.
    pub client_version: Option<String>,
    /// True for the device making the request, so the UI can label it and can
    /// warn before someone signs themselves out.
    pub is_current: bool,
}

impl Store {
    // --- Devices ---

    /// The account's *live* devices, newest first, flagging the caller's own.
    ///
    /// A sign-in without an install id mints a fresh device row
    /// (`Store::open_session_as`) and nothing ever deletes one except an
    /// explicit `Store::remove_device`, so without a filter here the list
    /// would only ever grow: a device signed
    /// out of a month ago would sit beside the one in active use, both
    /// offering the same "sign out" action for a session that, for one of
    /// them, no longer exists to sign out of.
    ///
    /// "Live" means a session that could still *rotate*: not explicitly
    /// revoked (`sessions.revoked_at`), and whose current refresh token - the
    /// one rotation has not yet spent (`used_at IS NULL`) or a reuse-detected
    /// replay revoked - has not simply expired from disuse either. A device
    /// whose owner walked away without ever tapping sign-out still needs to
    /// disappear once that expiry passes, or the list never reflects an
    /// abandoned device at all, only a deliberately removed one.
    ///
    /// Deliberately not the same question as [`Store::authenticate`], which
    /// reads only `access_tokens.expires_at` and never looks at the session
    /// row or the refresh token: a device can still be answering requests on
    /// an unexpired access token while listed here as gone. That window is at
    /// most one access-token lifetime and closes on its own.
    ///
    /// [`Store::push_targets`] must ask exactly this, or a device drops off
    /// this list while still being notified and the owner is left with no
    /// handle on something that keeps buzzing. `tests/device_liveness.rs`
    /// fails if the two diverge.
    pub async fn list_devices(
        &self,
        user_id: UserId,
        current: DeviceId,
    ) -> anyhow::Result<Vec<Device>> {
        let now = now_ms();
        let rows = sqlx::query!(
            r#"SELECT d.id AS "id!: DeviceId", d.name AS "name!",
                      d.created_at AS "created_at!", d.last_seen_at,
                      d.client_kind, d.client_version
               FROM devices d
               WHERE d.user_id = ?
                 AND EXISTS (
                   SELECT 1 FROM sessions s
                   JOIN refresh_tokens r ON r.session_id = s.id
                   WHERE s.device_id = d.id
                     AND s.revoked_at IS NULL
                     AND r.used_at IS NULL
                     AND r.revoked_at IS NULL
                     AND r.expires_at > ?
                 )
               ORDER BY d.created_at DESC"#,
            user_id,
            now
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| Device {
                is_current: r.id == current,
                id: r.id,
                name: r.name,
                created_at: r.created_at,
                last_seen_at: r.last_seen_at,
                client_kind: r.client_kind,
                client_version: r.client_version,
            })
            .collect())
    }

    /// Removes a device from the account and revokes its sessions. Returns the
    /// sessions that were killed so live sockets can be closed. `None` when the
    /// device is not on this account, so one user cannot sign another out.
    ///
    /// Ownership check, session lookup, revocation and the device delete all
    /// share one `BEGIN IMMEDIATE` transaction: the four used to run as
    /// separate statements (the last two against `self.pool` directly, after
    /// a since-removed helper had already committed its own revocation), so a
    /// failure between them could leave the device deleted with a session
    /// still live, or revoked with the device row still sitting there. Uses
    /// [`revoke_session_rows`] directly, in this transaction, rather than a
    /// helper that opens its own and so cannot join it.
    pub async fn remove_device(
        &self,
        user_id: UserId,
        device_id: DeviceId,
    ) -> anyhow::Result<Option<Vec<SessionId>>> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let owned = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM devices WHERE id = ? AND user_id = ?"#,
            device_id,
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if owned.is_none() {
            return Ok(None);
        }

        let sessions: Vec<SessionId> = sqlx::query!(
            r#"SELECT id AS "id!: SessionId" FROM sessions WHERE device_id = ?"#,
            device_id
        )
        .fetch_all(&mut *tx)
        .await?
        .into_iter()
        .map(|r| r.id)
        .collect();
        for session_id in &sessions {
            revoke_session_rows(&mut tx, *session_id, now).await?;
        }

        // The device row itself; cascade removes its now-revoked session rows too.
        sqlx::query!("DELETE FROM devices WHERE id = ?", device_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(Some(sessions))
    }

    // --- Blocking ---

    /// Blocks a user. Idempotent, and deliberately silent: the blocked user is
    /// never told, because telling them turns blocking into a provocation.
    /// Whether a user id has ever named a real account, tombstoned or not.
    ///
    /// A report or a block about a `user` must name someone real, or the
    /// moderation queue takes reports about random ids no foreign key bounds,
    /// and a block insert hits a foreign-key violation `INSERT OR IGNORE` does
    /// not cover. A deleted account still counts: you can report or block
    /// someone who has since left, and their tombstone row satisfies the key.
    pub async fn user_row_exists(&self, id: UserId) -> anyhow::Result<bool> {
        let found = sqlx::query_scalar!(
            r#"SELECT EXISTS(SELECT 1 FROM users WHERE id = ?) AS "found!: bool""#,
            id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(found)
    }

    pub async fn block_user(&self, blocker: UserId, blocked: UserId) -> anyhow::Result<bool> {
        if blocker == blocked {
            return Ok(false);
        }
        let now = now_ms();
        let affected = sqlx::query!(
            "INSERT OR IGNORE INTO user_blocks (blocker_id, blocked_id, created_at)
             VALUES (?, ?, ?)",
            blocker,
            blocked,
            now
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }

    pub async fn unblock_user(&self, blocker: UserId, blocked: UserId) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?",
            blocker,
            blocked
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Who this user has blocked, for the client to filter its own read
    /// surfaces with. Blocking is one viewer's view choice, never a moderation
    /// action, so the transcript every other member sees is unaffected and the
    /// blocked user is never told.
    ///
    /// The client is the right place for most of it: keeping a blocked author's
    /// messages in the local database and hiding them at read time is what
    /// makes unblocking instant and complete, where filtering them out of
    /// `/sync` would mean they never arrive and only a reset could recover
    /// them. Two things it cannot do for itself are handled server-side beside
    /// this - reaction counts, which carry no reactor ids by design
    /// ([`Store::reactions_for_messages`]), and push, which reaches the device
    /// before any filter runs ([`Store::blockers_of`]).
    pub async fn blocked_users(&self, blocker: UserId) -> anyhow::Result<Vec<UserId>> {
        let rows = sqlx::query!(
            r#"SELECT blocked_id AS "blocked_id!: UserId"
               FROM user_blocks WHERE blocker_id = ? ORDER BY created_at DESC"#,
            blocker
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| r.blocked_id).collect())
    }

    /// Who has blocked this user, the reverse direction of
    /// [`Store::blocked_users`].
    ///
    /// Push fan-out needs it: a notification is delivered before any client-side
    /// filter can run, so without this the loudest surface in the product is the
    /// one blocking does not cover. A phone buzzing for a message the app then
    /// hides is worse than not filtering at all, because it tells the reader
    /// exactly when the person they blocked spoke.
    ///
    /// Unbounded on purpose rather than taking a candidate list: the number of
    /// people who have blocked any one member is small in the deployments this
    /// is built for, and the alternative is a second query shape to keep in step
    /// with this one. Migration 0022 indexes the column it filters on.
    pub async fn blockers_of(&self, blocked: UserId) -> anyhow::Result<Vec<UserId>> {
        let rows = sqlx::query!(
            r#"SELECT blocker_id AS "blocker_id!: UserId"
               FROM user_blocks WHERE blocked_id = ?"#,
            blocked
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| r.blocker_id).collect())
    }

    /// Which of `candidates` the `viewer` has blocked. Reads `user_blocks`
    /// fresh on every call, deliberately uncached, so a block made a moment
    /// ago is reflected the very next read rather than sitting behind a stale
    /// answer - the live-reaction-undoing-a-block bug `blocking_live.rs`
    /// guards against was a precomputed *tally*, not this kind of read, but
    /// the same staleness would reintroduce it.
    ///
    /// Sized for a small, per-event candidate list (a live reaction's distinct
    /// reactors), not a broad audit; chunked under SQLite's bind cap regardless
    /// so a large list cannot fail the query outright.
    pub async fn blocked_among(
        &self,
        viewer: UserId,
        candidates: &[UserId],
    ) -> anyhow::Result<HashSet<UserId>> {
        use sqlx::Row;
        let mut blocked = HashSet::new();
        // Reserve one bind for viewer under the chunk limit; empty makes no chunks.
        for chunk in candidates.chunks(super::MAX_IDS_PER_QUERY - 1) {
            let mut builder =
                QueryBuilder::new("SELECT blocked_id FROM user_blocks WHERE blocker_id = ");
            builder.push_bind(viewer);
            builder.push(" AND blocked_id IN (");
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                blocked.insert(row.try_get("blocked_id")?);
            }
        }
        Ok(blocked)
    }

    /// Everyone `viewer` has blocked, for a caller that checks many candidates against one list.
    pub async fn blocked_ids(&self, viewer: UserId) -> anyhow::Result<HashSet<UserId>> {
        let ids = sqlx::query_scalar!(
            r#"SELECT blocked_id AS "blocked_id: UserId" FROM user_blocks WHERE blocker_id = ?"#,
            viewer
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(ids.into_iter().collect())
    }

    pub async fn has_blocked(&self, blocker: UserId, blocked: UserId) -> anyhow::Result<bool> {
        let found = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM user_blocks
               WHERE blocker_id = ? AND blocked_id = ?"#,
            blocker,
            blocked
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(found.is_some())
    }
}

/// Records that a device was just used. Called on sign-in, refresh and socket
/// connect only, never per request, so listing devices costs no write load.
pub(super) async fn touch_device(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    device_id: DeviceId,
    now: i64,
) -> anyhow::Result<()> {
    sqlx::query!(
        "UPDATE devices SET last_seen_at = ? WHERE id = ?",
        now,
        device_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
