// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The durable half of a watch party's shared position. See
//! docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.

use sqlx::Row;
use sqlx::sqlite::SqliteRow;

use crate::ids::{ChannelId, UserId};

use super::Store;

/// A session nobody refreshed for this long is over; the bot's tick is its heartbeat.
pub const WATCH_SESSION_TTL_MS: i64 = 30_000;

#[derive(Debug, Clone)]
pub struct WatchSession {
    pub channel_id: ChannelId,
    pub bot_user_id: UserId,
    pub item_id: String,
    pub title: String,
    pub duration_ms: Option<i64>,
    pub playing: bool,
    pub position_ms: i64,
    pub sampled_at: i64,
    pub epoch: i64,
    pub controller_user_id: Option<UserId>,
    /// The JSON object the bot states about direct play, or `None` when it offers none.
    pub direct_play: Option<String>,
}

/// What a bot states when it sets the session.
#[derive(Debug, Clone)]
pub struct WatchSessionWrite {
    pub item_id: String,
    pub title: String,
    pub duration_ms: Option<i64>,
    pub playing: bool,
    pub position_ms: i64,
    pub seeked: bool,
    pub controller_user_id: Option<UserId>,
    pub direct_play: Option<String>,
}

/// Whether a write landed.
#[derive(Debug, PartialEq, Eq)]
pub enum WatchWriteOutcome {
    Written(WatchSample),
    HeldByAnotherBot,
}

/// The part of a session a tick carries: where it is, sampled when.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchSample {
    pub bot_user_id: UserId,
    pub item_id: String,
    pub playing: bool,
    pub position_ms: i64,
    pub sampled_at: i64,
    pub epoch: i64,
}

fn from_row(row: &SqliteRow) -> WatchSession {
    WatchSession {
        channel_id: row.get("channel_id"),
        bot_user_id: row.get("bot_user_id"),
        item_id: row.get("item_id"),
        title: row.get("title"),
        duration_ms: row.get("duration_ms"),
        playing: row.get::<i64, _>("playing") != 0,
        position_ms: row.get("position_ms"),
        sampled_at: row.get("sampled_at"),
        epoch: row.get("epoch"),
        controller_user_id: row.get("controller_user_id"),
        direct_play: row.get("direct_play"),
    }
}

impl Store {
    /// The live session for a channel, or `None` once it has gone unrefreshed past the TTL.
    pub async fn watch_session(
        &self,
        channel: ChannelId,
        now: i64,
    ) -> anyhow::Result<Option<WatchSession>> {
        let row = sqlx::query("SELECT * FROM watch_sessions WHERE channel_id = ?")
            .bind(channel)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row
            .map(|r| from_row(&r))
            .filter(|s| now - s.sampled_at <= WATCH_SESSION_TTL_MS))
    }

    /// Sets the session, bumping the epoch on a new title or an explicit seek.
    ///
    /// Another bot's session is replaced only once it has expired or its bot
    /// is no longer on the call, as told by `owner_in_call`. An epoch is the
    /// write's own millisecond timestamp or one past the last, so it never
    /// repeats across an end and a fresh session.
    pub async fn put_watch_session(
        &self,
        channel: ChannelId,
        bot: UserId,
        write: &WatchSessionWrite,
        now: i64,
        owner_in_call: impl Fn(UserId) -> bool,
    ) -> anyhow::Result<WatchWriteOutcome> {
        let mut tx = self.begin_write().await?;
        let existing = sqlx::query("SELECT * FROM watch_sessions WHERE channel_id = ?")
            .bind(channel)
            .fetch_optional(&mut *tx)
            .await?
            .map(|r| from_row(&r));
        let epoch = match &existing {
            Some(s)
                if s.bot_user_id != bot
                    && now - s.sampled_at <= WATCH_SESSION_TTL_MS
                    && owner_in_call(s.bot_user_id) =>
            {
                return Ok(WatchWriteOutcome::HeldByAnotherBot);
            }
            // A bot back after the session lapsed may be anywhere, so viewers must resync.
            Some(s)
                if s.bot_user_id == bot
                    && s.item_id == write.item_id
                    && !write.seeked
                    && now - s.sampled_at <= WATCH_SESSION_TTL_MS =>
            {
                s.epoch
            }
            Some(s) => (s.epoch + 1).max(now),
            None => now,
        };
        sqlx::query(
            "INSERT INTO watch_sessions
                (channel_id, bot_user_id, item_id, title, duration_ms, playing,
                 position_ms, sampled_at, epoch, controller_user_id, direct_play)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(channel_id) DO UPDATE SET
                bot_user_id = excluded.bot_user_id, item_id = excluded.item_id,
                title = excluded.title, duration_ms = excluded.duration_ms,
                playing = excluded.playing, position_ms = excluded.position_ms,
                sampled_at = excluded.sampled_at, epoch = excluded.epoch,
                controller_user_id = excluded.controller_user_id,
                direct_play = excluded.direct_play",
        )
        .bind(channel)
        .bind(bot)
        .bind(&write.item_id)
        .bind(&write.title)
        .bind(write.duration_ms)
        .bind(i64::from(write.playing))
        .bind(write.position_ms)
        .bind(now)
        .bind(epoch)
        .bind(write.controller_user_id)
        .bind(&write.direct_play)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(WatchWriteOutcome::Written(WatchSample {
            bot_user_id: bot,
            item_id: write.item_id.clone(),
            playing: write.playing,
            position_ms: write.position_ms,
            sampled_at: now,
            epoch,
        }))
    }

    /// Re-samples the position of the caller's own live session; `None` when it has none.
    pub async fn tick_watch_session(
        &self,
        channel: ChannelId,
        bot: UserId,
        playing: bool,
        position_ms: i64,
        now: i64,
    ) -> anyhow::Result<Option<WatchSample>> {
        let row = sqlx::query(
            "UPDATE watch_sessions
             SET playing = ?, position_ms = ?, sampled_at = ?
             WHERE channel_id = ? AND bot_user_id = ? AND ? - sampled_at <= ?
             RETURNING item_id, epoch",
        )
        .bind(i64::from(playing))
        .bind(position_ms)
        .bind(now)
        .bind(channel)
        .bind(bot)
        .bind(now)
        .bind(WATCH_SESSION_TTL_MS)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| WatchSample {
            bot_user_id: bot,
            item_id: r.get("item_id"),
            playing,
            position_ms,
            sampled_at: now,
            epoch: r.get("epoch"),
        }))
    }

    /// Ends the caller's own session, returning its last sample when there was one.
    pub async fn end_watch_session(
        &self,
        channel: ChannelId,
        bot: UserId,
    ) -> anyhow::Result<Option<WatchSample>> {
        let row = sqlx::query(
            "DELETE FROM watch_sessions WHERE channel_id = ? AND bot_user_id = ?
             RETURNING item_id, playing, position_ms, sampled_at, epoch",
        )
        .bind(channel)
        .bind(bot)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| WatchSample {
            bot_user_id: bot,
            item_id: r.get("item_id"),
            playing: r.get::<i64, _>("playing") != 0,
            position_ms: r.get("position_ms"),
            sampled_at: r.get("sampled_at"),
            epoch: r.get("epoch"),
        }))
    }
}
