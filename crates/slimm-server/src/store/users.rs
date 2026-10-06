// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! User profile persistence: public profile reads, the caller's own
//! display-name update, and the member list.
//!
//! Every read here filters `deleted_at IS NULL`, so a deleted or anonymized
//! account answers exactly like an id that was never used: existence must not
//! be observable here any more than it is for a channel or a message.

use sqlx::QueryBuilder;
use uuid::Uuid;

use super::{Store, User};
use crate::ids::{ChannelId, UserId};

/// The fields [`Store::update_profile`] may change, one entry per column. A
/// struct rather than five positional parameters, so a caller passing only
/// `about` cannot mis-order it against `pronouns`.
///
/// Every field is `Option<Option<_>>`: a bare `None` leaves the column as it
/// was, `Some(None)` clears it, and `Some(Some(value))` writes it - see
/// [`Store::update_profile`]'s own doc for why.
#[derive(Debug, Clone, Copy, Default)]
pub struct ProfileUpdate<'a> {
    pub display_name: Option<&'a str>,
    pub status_text: Option<Option<&'a str>>,
    pub pronouns: Option<Option<&'a str>>,
    pub about: Option<Option<&'a str>>,
    /// Absent leaves the colour untouched. There is no clear-to-null case:
    /// every account always has one, defaulting deterministically when unset
    /// (see `http/users.rs::to_dtos`), so unlike the text fields above there
    /// is nothing meaningful to clear back to.
    pub profile_color: Option<i64>,
}

impl Store {
    /// A user's public profile: id, username, display name, and creation
    /// time. Nothing from the auth tables (password hash, sessions, tokens)
    /// is reachable through this path.
    ///
    /// A deleted or anonymized account answers `None`, the same as an id
    /// that was never used, so this cannot confirm someone deleted their
    /// account.
    pub async fn user_profile(&self, id: UserId) -> anyhow::Result<Option<User>> {
        let row = sqlx::query!(
            r#"SELECT id AS "id!: UserId", username AS "username!",
                      display_name AS "display_name!", created_at AS "created_at!",
                      avatar_updated_at, status_text, pronouns, about,
                      profile_color, is_bot AS "is_bot!",
                      is_webhook AS "is_webhook!"
               FROM users WHERE id = ? AND deleted_at IS NULL"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| User {
            id: r.id,
            username: r.username,
            display_name: r.display_name,
            created_at: r.created_at,
            avatar_updated_at: r.avatar_updated_at,
            status_text: r.status_text,
            pronouns: r.pronouns,
            about: r.about,
            profile_color: r.profile_color,
            is_bot: r.is_bot != 0,
            is_webhook: r.is_webhook != 0,
        }))
    }

    /// Public profiles for a batch of ids, in one query. An id with nothing
    /// live to report (never existed, or deleted) is simply absent from the
    /// result; the caller must treat a missing id that way rather than
    /// expecting one entry per input, the same contract
    /// [`Store::reactions_for_messages`] has for a message with no reactions.
    pub async fn user_profiles(&self, ids: &[UserId]) -> anyhow::Result<Vec<User>> {
        use sqlx::Row;

        // Chunked under SQLite's bind limit so a large id list cannot fail the query; empty makes no chunks.
        let mut users = Vec::with_capacity(ids.len());
        for chunk in ids.chunks(super::MAX_IDS_PER_QUERY) {
            // Built rather than a fixed `query!` because the id list is variable
            // length and SQLite has no array binding.
            let mut builder = QueryBuilder::new(
                "SELECT id, username, display_name, created_at, avatar_updated_at, status_text, \
                 pronouns, about, profile_color, is_bot, is_webhook FROM users \
                 WHERE deleted_at IS NULL AND id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");

            for row in builder.build().fetch_all(&self.pool).await? {
                users.push(User {
                    id: row.try_get("id")?,
                    username: row.try_get("username")?,
                    display_name: row.try_get("display_name")?,
                    created_at: row.try_get("created_at")?,
                    avatar_updated_at: row.try_get("avatar_updated_at")?,
                    status_text: row.try_get("status_text")?,
                    pronouns: row.try_get("pronouns")?,
                    about: row.try_get("about")?,
                    profile_color: row.try_get("profile_color")?,
                    is_bot: row.try_get::<i64, _>("is_bot")? != 0,
                    is_webhook: row.try_get::<i64, _>("is_webhook")? != 0,
                });
            }
        }
        Ok(users)
    }

    /// The live ids behind a batch of usernames, case-insensitively, for
    /// resolving a message's `@name` mentions to accounts. This deliberately
    /// disagrees with login's exact-case comparison: `channel_screen.dart`
    /// builds `knownUsernames` lowercased and `message_text.dart` matches a
    /// typed `@name` against it lowercased too, so a mention chip renders
    /// for any case a reader typed, and the wake it triggers has to agree or
    /// it silently fails for every case but the one stored. A name with
    /// nobody live behind it - never registered, or deleted - is simply
    /// absent, the same contract [`Store::user_profiles`] has for an id.
    ///
    /// Live usernames are unique case-insensitively (`users_username_lower_live`,
    /// migration 0095), so the lowered lookup resolves at most one id per
    /// name. The lowering is still needed to agree with how the client
    /// renders a mention chip.
    pub async fn user_ids_for_usernames(
        &self,
        usernames: &[String],
    ) -> anyhow::Result<Vec<UserId>> {
        if usernames.is_empty() {
            return Ok(Vec::new());
        }

        let mut builder = QueryBuilder::new(
            "SELECT id FROM users WHERE deleted_at IS NULL AND LOWER(username) IN (",
        );
        let mut separated = builder.separated(", ");
        for name in usernames {
            separated.push_bind(name.to_lowercase());
        }
        builder.push(")");

        let ids: Vec<UserId> = builder.build_query_scalar().fetch_all(&self.pool).await?;
        Ok(ids)
    }

    /// Updates the caller's own profile fields - a struct rather than five
    /// positional parameters, one per column. Every field is `Option<Option<_>>`:
    /// a bare `None` leaves the column exactly as it was, `Some(None)` clears
    /// it to `NULL`, and `Some(Some(value))` writes it - the same
    /// "absent leaves it untouched, present-and-empty clears it" convention
    /// [`Store::update_channel`] uses for a channel's topic. Username is not
    /// updatable here: it backs the live per-account uniqueness index
    /// (`users_username_live`), and changing it needs a dedicated flow that
    /// can handle the resulting collision, not a field silently accepted (or
    /// silently ignored) here.
    ///
    /// Returns `None` if the account is gone: the same tiny window
    /// documented on [`Store::delete_account`], where a write already in
    /// flight on a token that was still valid when the request started can
    /// land just after a concurrent deletion.
    pub async fn update_profile(
        &self,
        user_id: UserId,
        update: ProfileUpdate<'_>,
    ) -> anyhow::Result<Option<User>> {
        let mut builder = QueryBuilder::new("UPDATE users SET ");
        let mut sets = builder.separated(", ");
        let mut touched = false;
        if let Some(display_name) = update.display_name {
            sets.push("display_name = ")
                .push_bind_unseparated(display_name);
            touched = true;
        }
        if let Some(status_text) = update.status_text {
            sets.push("status_text = ")
                .push_bind_unseparated(status_text);
            touched = true;
        }
        if let Some(pronouns) = update.pronouns {
            sets.push("pronouns = ").push_bind_unseparated(pronouns);
            touched = true;
        }
        if let Some(about) = update.about {
            sets.push("about = ").push_bind_unseparated(about);
            touched = true;
        }
        if let Some(profile_color) = update.profile_color {
            sets.push("profile_color = ")
                .push_bind_unseparated(profile_color);
            touched = true;
        }

        let affected = if touched {
            builder.push(" WHERE id = ");
            builder.push_bind(user_id);
            builder.push(" AND deleted_at IS NULL");
            builder.build().execute(&self.pool).await?.rows_affected()
        } else {
            let exists = sqlx::query_scalar!(
                r#"SELECT 1 AS "one!: i64" FROM users WHERE id = ? AND deleted_at IS NULL"#,
                user_id
            )
            .fetch_optional(&self.pool)
            .await?;
            u64::from(exists.is_some())
        };
        if affected == 0 {
            return Ok(None);
        }
        self.user_profile(user_id).await
    }

    /// How many live accounts this deployment has. Used to show a
    /// prospective joiner, via an invite's metadata, roughly how big the
    /// community is before they sign up; a deleted or anonymized account
    /// does not count, and neither does a webhook's principal or a removed one, any more than either
    /// appears in [`Store::list_members`] or is counted by
    /// [`super::roles::administrator_count`].
    pub async fn member_count(&self) -> anyhow::Result<i64> {
        let count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "count!: i64" FROM users
               WHERE deleted_at IS NULL AND is_webhook = 0
               AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = users.id)"#
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(count)
    }

    /// Every live, non-removed account's id, unpaginated - the candidate
    /// pool [`crate::mentions::mentioned_viewers`] narrows with
    /// [`super::permissions_batch`]'s own `viewers_among` to decide who a
    /// message actually mentions. Deployment-wide like
    /// [`super::push::users_with_push_devices`] for the same reason: a
    /// mention badge is not limited to whoever has registered for push, and
    /// a self-host's whole membership is the bound this project already
    /// accepts for that query.
    ///
    /// Excludes a webhook's principal: it is not a participant candidate for
    /// anything a mention could wake, the same "not mentionable, not
    /// resolvable to a user" the per-post `username` label already has, and
    /// keeping it out of this pool is what makes that true rather than merely
    /// intended. See `docs/decisions/0030-incoming-webhooks.md`.
    pub async fn all_live_user_ids(&self) -> anyhow::Result<Vec<UserId>> {
        let rows = sqlx::query_scalar!(
            r#"SELECT id AS "id!: UserId" FROM users
               WHERE deleted_at IS NULL AND is_webhook = 0
               AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = users.id)"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// The deployment's live members, oldest first, keyset-paginated by id.
    /// UUIDv7 sorts chronologically, so id order is already creation order
    /// and no separate cursor column is needed.
    ///
    /// Excludes a webhook's principal: it holds one verb on one channel and
    /// is not a participant, so a member list padded with alert feeds would
    /// be noise. See `docs/decisions/0030-incoming-webhooks.md`; a webhook's
    /// principal is still readable through [`Self::user_profile`], which a
    /// message's own author id resolves through.
    pub async fn list_members(
        &self,
        after: Option<UserId>,
        limit: i64,
    ) -> anyhow::Result<Vec<User>> {
        let after = after.unwrap_or(UserId(Uuid::nil()));
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: UserId", username AS "username!",
                      display_name AS "display_name!", created_at AS "created_at!",
                      avatar_updated_at, status_text, pronouns, about,
                      profile_color, is_bot AS "is_bot!",
                      is_webhook AS "is_webhook!"
               FROM users WHERE deleted_at IS NULL AND is_webhook = 0 AND id > ?
               AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = users.id)
               ORDER BY id ASC LIMIT ?"#,
            after,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| User {
                id: r.id,
                username: r.username,
                display_name: r.display_name,
                created_at: r.created_at,
                avatar_updated_at: r.avatar_updated_at,
                status_text: r.status_text,
                pronouns: r.pronouns,
                about: r.about,
                profile_color: r.profile_color,
                is_bot: r.is_bot != 0,
                is_webhook: r.is_webhook != 0,
            })
            .collect())
    }

    /// The live members who can view `channel_id`, in the same order and with
    /// the same keyset contract as [`Self::list_members`].
    ///
    /// The filter cannot be applied after a page is cut. A caller pages until
    /// it gets one shorter than it asked for, so dropping rows from a full
    /// page would read as the end of the roster and silently truncate it.
    /// This walks candidate pages instead and stops once `limit` viewers are
    /// in hand, so a short page still means what it always meant.
    ///
    /// Visibility itself is [`Self::viewers_among`], not a second evaluator:
    /// that path already resolves threads to their parent, handles a DM's
    /// pair, and carries an equivalence test against the per-user answer.
    pub async fn list_members_who_view(
        &self,
        channel_id: ChannelId,
        after: Option<UserId>,
        limit: i64,
    ) -> anyhow::Result<Vec<User>> {
        let mut viewers = Vec::new();
        let mut cursor = after;
        while (viewers.len() as i64) < limit {
            let candidates = self.list_members(cursor, limit).await?;
            let exhausted = (candidates.len() as i64) < limit;
            if candidates.is_empty() {
                break;
            }
            cursor = candidates.last().map(|user| user.id);

            let ids: Vec<UserId> = candidates.iter().map(|user| user.id).collect();
            let allowed = self.viewers_among(channel_id, &ids).await?;
            for user in candidates {
                if allowed.contains(&user.id) {
                    viewers.push(user);
                    if (viewers.len() as i64) == limit {
                        return Ok(viewers);
                    }
                }
            }
            if exhausted {
                break;
            }
        }
        Ok(viewers)
    }

    /// Marks the caller's avatar as freshly set, stamping `avatar_updated_at`
    /// with now. Called after the bytes are already written to disk (see
    /// `Media::write_avatar`), never before: the file-then-row ordering means
    /// a crash between the two steps leaves the old avatar's timestamp
    /// pointing at bytes that were just overwritten, not a row that promises
    /// an avatar no file backs.
    ///
    /// Returns `None` if the account is gone, the same tiny race documented
    /// on [`Store::update_profile`].
    pub async fn set_avatar_updated(&self, user_id: UserId) -> anyhow::Result<Option<User>> {
        let now = super::now_ms();
        let affected = sqlx::query!(
            "UPDATE users SET avatar_updated_at = ? WHERE id = ? AND deleted_at IS NULL",
            now,
            user_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        if affected == 0 {
            return Ok(None);
        }
        self.user_profile(user_id).await
    }

    /// Clears the caller's avatar. The file itself is removed by the caller
    /// (`Media::delete_avatar`) after this succeeds.
    pub async fn clear_avatar(&self, user_id: UserId) -> anyhow::Result<Option<User>> {
        let affected = sqlx::query!(
            "UPDATE users SET avatar_updated_at = NULL WHERE id = ? AND deleted_at IS NULL",
            user_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        if affected == 0 {
            return Ok(None);
        }
        self.user_profile(user_id).await
    }
}
