// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice channel's call history (decision 0066): the joins, leaves and
//! screen shares the LiveKit webhook reports. Calls are worked out from
//! these by [`crate::call_history`] when read.

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};

/// How long call history is kept.
pub const CALL_HISTORY_RETENTION_DAYS: i64 = 30;

/// The most events one read considers, newest first; at a few dozen per call
/// this is far more than the ten calls a read returns.
const MAX_EVENTS_READ: i64 = 5000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceEventKind {
    Joined,
    Left,
    ShareStarted,
    ShareStopped,
}

impl VoiceEventKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Joined => "joined",
            Self::Left => "left",
            Self::ShareStarted => "share_started",
            Self::ShareStopped => "share_stopped",
        }
    }

    fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "joined" => Self::Joined,
            "left" => Self::Left,
            "share_started" => Self::ShareStarted,
            "share_stopped" => Self::ShareStopped,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VoiceEvent {
    pub at: i64,
    pub user_id: UserId,
    pub kind: VoiceEventKind,
}

/// What was put on a channel's canvas by one person, of one kind, inside a
/// time span: when the first one landed and how many.
#[derive(Debug, Clone)]
pub struct CanvasActivity {
    pub user_id: UserId,
    pub kind: String,
    pub first_at: i64,
    pub count: i64,
}

impl Store {
    pub async fn record_voice_event(
        &self,
        channel: ChannelId,
        user: UserId,
        kind: VoiceEventKind,
        at: i64,
    ) -> anyhow::Result<()> {
        let kind = kind.as_str();
        sqlx::query!(
            "INSERT INTO voice_call_events (channel_id, at, user_id, kind) VALUES (?, ?, ?, ?)",
            channel,
            at,
            user,
            kind
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// The channel's events inside the retention window, oldest first.
    pub async fn voice_events(&self, channel: ChannelId) -> anyhow::Result<Vec<VoiceEvent>> {
        let since = now_ms() - CALL_HISTORY_RETENTION_DAYS * 24 * 60 * 60 * 1000;
        let rows = sqlx::query!(
            r#"SELECT at AS "at!", user_id AS "user_id!: UserId", kind AS "kind!"
               FROM (SELECT at, user_id, kind FROM voice_call_events
                     WHERE channel_id = ? AND at >= ?
                     ORDER BY at DESC LIMIT ?)
               ORDER BY at"#,
            channel,
            since,
            MAX_EVENTS_READ
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .filter_map(|r| {
                Some(VoiceEvent {
                    at: r.at,
                    user_id: r.user_id,
                    kind: VoiceEventKind::parse(&r.kind)?,
                })
            })
            .collect())
    }

    /// Canvas objects placed in `channel` between `from` and `to`, grouped
    /// per author and kind; deleted ones count, since they were still placed.
    pub async fn canvas_activity_between(
        &self,
        channel: ChannelId,
        from: i64,
        to: i64,
    ) -> anyhow::Result<Vec<CanvasActivity>> {
        let rows = sqlx::query!(
            r#"SELECT author_id AS "user_id!: UserId", kind AS "kind!",
                      MIN(created_at) AS "first_at!: i64", COUNT(*) AS "count!: i64"
               FROM canvas_objects
               WHERE channel_id = ? AND created_at >= ? AND created_at <= ?
                 AND author_id IS NOT NULL
               GROUP BY author_id, kind
               ORDER BY MIN(created_at)"#,
            channel,
            from,
            to
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| CanvasActivity {
                user_id: r.user_id,
                kind: r.kind,
                first_at: r.first_at,
                count: r.count,
            })
            .collect())
    }

    /// Live objects on `channel`'s canvas right now.
    pub async fn canvas_object_count(&self, channel: ChannelId) -> anyhow::Result<i64> {
        Ok(sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM canvas_objects
               WHERE channel_id = ? AND deleted_at IS NULL"#,
            channel
        )
        .fetch_one(&self.pool)
        .await?)
    }

    /// Deletes events past the retention window; the sweep calls this.
    pub async fn sweep_voice_events(&self) -> anyhow::Result<u64> {
        let before = now_ms() - CALL_HISTORY_RETENTION_DAYS * 24 * 60 * 60 * 1000;
        Ok(
            sqlx::query!("DELETE FROM voice_call_events WHERE at < ?", before)
                .execute(&self.pool)
                .await?
                .rows_affected(),
        )
    }
}
