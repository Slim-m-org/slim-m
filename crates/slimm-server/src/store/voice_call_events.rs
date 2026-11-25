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

/// One canvas object placed by someone, as read for call history.
#[derive(Debug, Clone)]
pub struct CanvasPlacement {
    pub user_id: UserId,
    pub kind: String,
    pub at: i64,
}

/// The placements inside `from..=to` grouped per author and kind, earliest group first.
pub fn bucket_activity(placements: &[CanvasPlacement], from: i64, to: i64) -> Vec<CanvasActivity> {
    let mut groups: Vec<CanvasActivity> = Vec::new();
    for placement in placements.iter().filter(|p| p.at >= from && p.at <= to) {
        match groups
            .iter_mut()
            .find(|g| g.user_id == placement.user_id && g.kind == placement.kind)
        {
            Some(group) => {
                group.first_at = group.first_at.min(placement.at);
                group.count += 1;
            }
            None => groups.push(CanvasActivity {
                user_id: placement.user_id,
                kind: placement.kind.clone(),
                first_at: placement.at,
                count: 1,
            }),
        }
    }
    groups.sort_by_key(|g| g.first_at);
    groups
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

    /// Every canvas object placed in `channel` between `from` and `to`, oldest first; deleted ones
    /// count, since they were still placed. One read serves every call in the span.
    pub async fn canvas_placements_between(
        &self,
        channel: ChannelId,
        from: i64,
        to: i64,
    ) -> anyhow::Result<Vec<CanvasPlacement>> {
        let rows = sqlx::query!(
            r#"SELECT author_id AS "user_id!: UserId", kind AS "kind!", created_at AS "at!: i64"
               FROM canvas_objects
               WHERE channel_id = ? AND created_at >= ? AND created_at <= ?
                 AND author_id IS NOT NULL
               ORDER BY created_at"#,
            channel,
            from,
            to
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| CanvasPlacement {
                user_id: r.user_id,
                kind: r.kind,
                at: r.at,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn placement(user: UserId, kind: &str, at: i64) -> CanvasPlacement {
        CanvasPlacement {
            user_id: user,
            kind: kind.to_string(),
            at,
        }
    }

    #[test]
    fn buckets_per_call_window_by_author_and_kind() {
        let (a, b) = (UserId::generate(), UserId::generate());
        let rows = [
            placement(a, "note", 5),
            placement(a, "note", 12),
            placement(b, "stroke", 14),
            placement(a, "note", 15),
            placement(a, "note", 30),
        ];
        let first = bucket_activity(&rows, 0, 20);
        assert_eq!(first.len(), 2);
        assert_eq!(
            (first[0].user_id, first[0].first_at, first[0].count),
            (a, 5, 3)
        );
        assert_eq!(
            (first[1].user_id, first[1].first_at, first[1].count),
            (b, 14, 1)
        );
        let second = bucket_activity(&rows, 21, 40);
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].count, 1);
    }
}
