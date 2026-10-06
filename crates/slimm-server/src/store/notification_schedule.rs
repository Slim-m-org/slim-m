// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for the notification schedule (migration 0081):
//! [`crate::notification_schedule::Schedule`] plus the two off-hours
//! allow-lists.
//!
//! No row in `notification_schedules` at all is a distinct, deliberate
//! state from a row with every weekday empty: absence means this account has
//! never turned the feature on, so push is never narrowed for it - the read
//! path (`notification_schedules_for_users`) simply omits an id with no row
//! from the map it returns, and `push::recipients` treats that exactly like
//! "always on hours". A row that exists with no days at all means the
//! account (or [`Store::set_notification_snooze`] acting on its behalf, see
//! that method's own doc) really does have every day off, which is a real
//! state a caller can reach on purpose.

use std::collections::{HashMap, HashSet};

use sqlx::QueryBuilder;

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};
use crate::notification_schedule::{DayWindow, OffHoursMode, Schedule};

/// One weekday's window as read from or written to `notification_schedule_days`.
#[derive(Debug, Clone, Copy)]
pub struct DaySetting {
    pub weekday: u8,
    pub window: DayWindow,
}

/// The full detail [`Store::notification_schedule`] hands back for the
/// caller's own settings screen: everything [`Schedule`] needs to evaluate,
/// plus both allow-lists, which [`Schedule`] itself does not carry (they are
/// looked up per message, by target, on the push path - see that struct's
/// own doc comment).
#[derive(Debug, Clone)]
pub struct NotificationScheduleDetail {
    pub schedule: Schedule,
    pub allowed_user_ids: Vec<UserId>,
    pub allowed_channel_ids: Vec<ChannelId>,
}

/// The always-on placeholder [`Store::set_notification_snooze`] writes for
/// an account with no schedule of its own yet: 00:00 to 23:59, a one-minute
/// daily gap that is never enforced in practice, standing in for "on all
/// day" without a special-cased zero-length window in the schema's CHECK
/// constraint.
const ALWAYS_ON_PLACEHOLDER: DayWindow = match DayWindow::parse(0, 1439) {
    Some(window) => window,
    None => unreachable!(),
};

impl Store {
    /// The caller's own schedule, or `None` if never configured - see this
    /// module's own doc comment for why that is distinct from a schedule
    /// with every day empty.
    pub async fn notification_schedule(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Option<NotificationScheduleDetail>> {
        let Some(header) = sqlx::query!(
            r#"SELECT timezone, off_hours_mode, snooze_until AS "snooze_until: i64"
               FROM notification_schedules WHERE user_id = ?"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?
        else {
            return Ok(None);
        };
        let off_hours_mode = OffHoursMode::parse(&header.off_hours_mode)
            .ok_or_else(|| anyhow::anyhow!("invalid off_hours_mode in storage"))?;

        let day_rows = sqlx::query!(
            r#"SELECT weekday AS "weekday: i64", start_minute AS "start: i64", end_minute AS "end: i64"
               FROM notification_schedule_days WHERE user_id = ?"#,
            user_id
        )
        .fetch_all(&self.pool)
        .await?;
        let mut days = [None; crate::notification_schedule::WEEKDAYS];
        for row in day_rows {
            if let Some(slot) = days.get_mut(row.weekday as usize) {
                *slot = DayWindow::parse(row.start, row.end);
            }
        }

        let allowed_user_ids = sqlx::query!(
            "SELECT allowed_user_id AS \"id: UserId\" FROM notification_schedule_allowed_users WHERE user_id = ?",
            user_id
        )
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(|r| r.id)
        .collect();

        let allowed_channel_ids = sqlx::query!(
            "SELECT allowed_channel_id AS \"id: ChannelId\" FROM notification_schedule_allowed_channels WHERE user_id = ?",
            user_id
        )
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(|r| r.id)
        .collect();

        Ok(Some(NotificationScheduleDetail {
            schedule: Schedule {
                timezone: header.timezone,
                days,
                off_hours_mode,
                snooze_until: header.snooze_until,
            },
            allowed_user_ids,
            allowed_channel_ids,
        }))
    }

    /// Replaces the caller's own timezone, off-hours mode and per-weekday
    /// windows in one transaction. Never touches `snooze_until` or either
    /// allow-list: those are their own routes, since a settings-screen save
    /// of the weekly grid should not accidentally clear a VIP list or an
    /// active snooze.
    pub async fn set_notification_schedule(
        &self,
        user_id: UserId,
        timezone: &str,
        off_hours_mode: OffHoursMode,
        days: &[DaySetting],
    ) -> anyhow::Result<()> {
        let mode = off_hours_mode.as_str();
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "INSERT INTO notification_schedules (user_id, timezone, off_hours_mode, snooze_until, updated_at)
             VALUES (?, ?, ?, NULL, ?)
             ON CONFLICT(user_id) DO UPDATE SET
                timezone = excluded.timezone,
                off_hours_mode = excluded.off_hours_mode,
                updated_at = excluded.updated_at",
            user_id,
            timezone,
            mode,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "DELETE FROM notification_schedule_days WHERE user_id = ?",
            user_id
        )
        .execute(&mut *tx)
        .await?;
        for day in days {
            let weekday = i64::from(day.weekday);
            let start = i64::from(day.window.start_minute);
            let end = i64::from(day.window.end_minute);
            sqlx::query!(
                "INSERT INTO notification_schedule_days (user_id, weekday, start_minute, end_minute)
                 VALUES (?, ?, ?, ?)",
                user_id,
                weekday,
                start,
                end
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Turns the schedule off entirely, back to "never configured" - the
    /// `ON DELETE CASCADE` on both child tables' `user_id` column takes the
    /// days and both allow-lists with it, a real `DELETE` rather than the
    /// account-deletion tombstone, so the cascade genuinely fires here.
    pub async fn clear_notification_schedule(&self, user_id: UserId) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM notification_schedules WHERE user_id = ?",
            user_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Sets or clears a snooze deadline. If the caller has never configured
    /// a schedule, this creates one first: an always-on placeholder (every
    /// weekday 00:00-23:59, [`OffHoursMode::MentionsAndDms`]) that changes
    /// nothing about ordinary push once the snooze itself expires, purely a
    /// place to hang `snooze_until`. A caller who goes on to configure a
    /// real weekly schedule overwrites this placeholder the ordinary way,
    /// through [`Store::set_notification_schedule`].
    pub async fn set_notification_snooze(
        &self,
        user_id: UserId,
        until_ms: Option<i64>,
    ) -> anyhow::Result<()> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let existed = sqlx::query!(
            "SELECT user_id AS \"id: UserId\" FROM notification_schedules WHERE user_id = ?",
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .is_some();

        if existed {
            sqlx::query!(
                "UPDATE notification_schedules SET snooze_until = ?, updated_at = ? WHERE user_id = ?",
                until_ms,
                now,
                user_id
            )
            .execute(&mut *tx)
            .await?;
        } else {
            let mode = OffHoursMode::MentionsAndDms.as_str();
            sqlx::query!(
                "INSERT INTO notification_schedules (user_id, timezone, off_hours_mode, snooze_until, updated_at)
                 VALUES (?, 'UTC', ?, ?, ?)",
                user_id,
                mode,
                until_ms,
                now
            )
            .execute(&mut *tx)
            .await?;
            let start = i64::from(ALWAYS_ON_PLACEHOLDER.start_minute);
            let end = i64::from(ALWAYS_ON_PLACEHOLDER.end_minute);
            for weekday in 0..crate::notification_schedule::WEEKDAYS as i64 {
                sqlx::query!(
                    "INSERT INTO notification_schedule_days (user_id, weekday, start_minute, end_minute)
                     VALUES (?, ?, ?, ?)",
                    user_id,
                    weekday,
                    start,
                    end
                )
                .execute(&mut *tx)
                .await?;
            }
        }
        tx.commit().await?;
        Ok(())
    }

    /// Adds `allowed_user_id` to the caller's off-hours people allow-list -
    /// the member card's "notify me about this person off-hours" action.
    /// Works with no schedule configured yet; it is simply inert until
    /// there is an off-hours window for it to break through.
    pub async fn add_notification_schedule_allowed_user(
        &self,
        user_id: UserId,
        allowed_user_id: UserId,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "INSERT OR IGNORE INTO notification_schedule_allowed_users (user_id, allowed_user_id)
             VALUES (?, ?)",
            user_id,
            allowed_user_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn remove_notification_schedule_allowed_user(
        &self,
        user_id: UserId,
        allowed_user_id: UserId,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM notification_schedule_allowed_users WHERE user_id = ? AND allowed_user_id = ?",
            user_id,
            allowed_user_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Adds `allowed_channel_id` to the caller's off-hours channel
    /// allow-list - the channel menu's "notify me off-hours here" action.
    pub async fn add_notification_schedule_allowed_channel(
        &self,
        user_id: UserId,
        allowed_channel_id: ChannelId,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "INSERT OR IGNORE INTO notification_schedule_allowed_channels (user_id, allowed_channel_id)
             VALUES (?, ?)",
            user_id,
            allowed_channel_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn remove_notification_schedule_allowed_channel(
        &self,
        user_id: UserId,
        allowed_channel_id: ChannelId,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM notification_schedule_allowed_channels WHERE user_id = ? AND allowed_channel_id = ?",
            user_id,
            allowed_channel_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Batched read for push fan-out: every `viewer_ids` with a configured
    /// schedule, one query for every recipient rather than one lookup each.
    /// An id absent from the map has never configured one, and
    /// reads at the call site as always on hours.
    pub async fn notification_schedules_for_users(
        &self,
        viewer_ids: &[UserId],
    ) -> anyhow::Result<HashMap<UserId, Schedule>> {
        if viewer_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let mut builder = QueryBuilder::new(
            "SELECT user_id, timezone, off_hours_mode, snooze_until FROM notification_schedules WHERE user_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in viewer_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        use sqlx::Row;
        let rows = builder.build().fetch_all(&self.pool).await?;
        let mut headers = HashMap::new();
        for row in &rows {
            let id: UserId = row.try_get("user_id")?;
            let timezone: String = row.try_get("timezone")?;
            let mode_raw: String = row.try_get("off_hours_mode")?;
            let snooze_until: Option<i64> = row.try_get("snooze_until")?;
            let Some(off_hours_mode) = OffHoursMode::parse(&mode_raw) else {
                continue;
            };
            headers.insert(
                id,
                Schedule {
                    timezone,
                    days: [None; crate::notification_schedule::WEEKDAYS],
                    off_hours_mode,
                    snooze_until,
                },
            );
        }
        if headers.is_empty() {
            return Ok(headers);
        }

        let mut builder = QueryBuilder::new(
            "SELECT user_id, weekday, start_minute, end_minute FROM notification_schedule_days WHERE user_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in headers.keys() {
            separated.push_bind(*id);
        }
        builder.push(")");
        let day_rows = builder.build().fetch_all(&self.pool).await?;
        for row in day_rows {
            let id: UserId = row.try_get("user_id")?;
            let weekday: i64 = row.try_get("weekday")?;
            let start: i64 = row.try_get("start_minute")?;
            let end: i64 = row.try_get("end_minute")?;
            if let Some(schedule) = headers.get_mut(&id)
                && let Some(slot) = schedule.days.get_mut(weekday as usize)
            {
                *slot = DayWindow::parse(start, end);
            }
        }
        Ok(headers)
    }

    /// Which of `viewer_ids` allow-list `author_id` off hours - the push
    /// path's other batched read, keyed the opposite way from the owner's
    /// own list (by the target, not the owner), since fan-out asks "who
    /// wants this specific author let through", not "what does one viewer's
    /// list contain".
    pub async fn viewers_allowing_author_off_hours(
        &self,
        viewer_ids: &[UserId],
        author_id: UserId,
    ) -> anyhow::Result<HashSet<UserId>> {
        if viewer_ids.is_empty() {
            return Ok(HashSet::new());
        }
        let mut builder = QueryBuilder::new(
            "SELECT user_id FROM notification_schedule_allowed_users WHERE allowed_user_id = ",
        );
        builder.push_bind(author_id);
        builder.push(" AND user_id IN (");
        let mut separated = builder.separated(", ");
        for id in viewer_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        use sqlx::Row;
        let rows = builder.build().fetch_all(&self.pool).await?;
        rows.into_iter()
            .map(|row| row.try_get::<UserId, _>("user_id").map_err(Into::into))
            .collect()
    }

    /// Which of `viewer_ids` allow-list `channel_id` off hours.
    ///
    /// `parent_channel_id` is a thread's parent channel, and `None` for every
    /// other channel: allow-listing a channel has to carry into its threads
    /// for the same reason muting one does, and only the preference lookup in
    /// [`Store::channel_notification_preferences`] is worded the other way
    /// round.
    pub async fn viewers_allowing_channel_off_hours(
        &self,
        viewer_ids: &[UserId],
        channel_id: ChannelId,
        parent_channel_id: Option<ChannelId>,
    ) -> anyhow::Result<HashSet<UserId>> {
        if viewer_ids.is_empty() {
            return Ok(HashSet::new());
        }
        let mut builder = QueryBuilder::new(
            "SELECT user_id FROM notification_schedule_allowed_channels WHERE allowed_channel_id IN (",
        );
        builder.push_bind(channel_id);
        if let Some(parent) = parent_channel_id {
            builder.push(", ");
            builder.push_bind(parent);
        }
        builder.push(")");
        builder.push(" AND user_id IN (");
        let mut separated = builder.separated(", ");
        for id in viewer_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        use sqlx::Row;
        let rows = builder.build().fetch_all(&self.pool).await?;
        rows.into_iter()
            .map(|row| row.try_get::<UserId, _>("user_id").map_err(Into::into))
            .collect()
    }
}
