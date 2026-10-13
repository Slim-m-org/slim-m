// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The join gate and raid mode.
//!
//! With the gate on, an account that registers waits in `pending_members`
//! until it accepts the Space's rules. A pending member's permissions are
//! capped wherever the timeout mask is applied, so no route needs its own
//! check: they can view the rules channel, and nothing else at all.
//! `joins_paused` refuses every new registration, invite or not.

use std::collections::HashSet;

use anyhow::Context;
use sqlx::SqliteExecutor;

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

/// Rules text cap, in characters.
pub const MAX_RULES_CHARS: usize = 4000;

/// The admin-facing settings, one row in `space_settings`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JoinGate {
    pub enabled: bool,
    pub rules: String,
    pub rules_channel_id: Option<ChannelId>,
    pub joins_paused: bool,
}

/// Whether a member has accepted the rules, and so what is withheld from them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemberGate {
    Member,
    Pending { rules_channel: Option<ChannelId> },
}

impl MemberGate {
    /// What to subtract in `channel`, or deployment-wide when `None`.
    pub fn deny_in(self, channel: Option<ChannelId>) -> Permissions {
        match self {
            Self::Member => Permissions::NONE,
            Self::Pending { rules_channel } if channel.is_some() && channel == rules_channel => {
                Permissions::ALL.remove(Permissions::VIEW_CHANNEL)
            }
            Self::Pending { .. } => Permissions::ALL,
        }
    }
}

pub(super) async fn read_join_gate<'e, E>(executor: E) -> anyhow::Result<JoinGate>
where
    E: SqliteExecutor<'e>,
{
    let row = sqlx::query!(
        r#"SELECT join_gate AS "enabled!: bool", rules_text AS "rules!: String",
                  rules_channel_id AS "rules_channel_id: ChannelId", joins_paused AS "joins_paused!: bool"
           FROM space_settings WHERE id = 1"#
    )
    .fetch_optional(executor)
    .await
    .context("read join gate")?;
    Ok(row.map_or(
        JoinGate {
            enabled: false,
            rules: String::new(),
            rules_channel_id: None,
            joins_paused: false,
        },
        |r| JoinGate {
            enabled: r.enabled,
            rules: r.rules,
            rules_channel_id: r.rules_channel_id,
            joins_paused: r.joins_paused,
        },
    ))
}

/// Puts a just-registered account behind the gate, inside its registration.
pub(super) async fn mark_pending(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
    now: i64,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "INSERT OR IGNORE INTO pending_members (user_id, since) VALUES (?, ?)",
        user_id,
        now
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}

impl Store {
    pub async fn join_gate(&self) -> anyhow::Result<JoinGate> {
        read_join_gate(&self.pool).await
    }

    /// Saves the settings. Turning the gate off lets everyone waiting in, so
    /// nobody is left behind a gate that no longer exists.
    pub async fn set_join_gate(&self, gate: &JoinGate) -> anyhow::Result<()> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "UPDATE space_settings SET join_gate = ?, rules_text = ?, rules_channel_id = ?,
                    joins_paused = ?, updated_at = ? WHERE id = 1",
            gate.enabled,
            gate.rules,
            gate.rules_channel_id,
            gate.joins_paused,
            now
        )
        .execute(&mut *tx)
        .await
        .context("set join gate")?;
        if !gate.enabled {
            sqlx::query!("DELETE FROM pending_members")
                .execute(&mut *tx)
                .await
                .context("release pending members")?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn member_gate(&self, user_id: UserId) -> anyhow::Result<MemberGate> {
        let row = sqlx::query!(
            r#"SELECT s.rules_channel_id AS "rules_channel_id: ChannelId"
               FROM pending_members p LEFT JOIN space_settings s ON s.id = 1
               WHERE p.user_id = ?"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await
        .context("read member gate")?;
        Ok(row.map_or(MemberGate::Member, |r| MemberGate::Pending {
            rules_channel: r.rules_channel_id,
        }))
    }

    /// Which of `candidates` are pending, in one query, for the fan-out paths.
    pub async fn pending_among(&self, candidates: &[UserId]) -> anyhow::Result<HashSet<UserId>> {
        let mut out = HashSet::new();
        for chunk in candidates.chunks(super::MAX_IDS_PER_QUERY) {
            let mut builder =
                sqlx::QueryBuilder::new("SELECT user_id FROM pending_members WHERE user_id IN (");
            let mut ids = builder.separated(", ");
            for id in chunk {
                ids.push_bind(*id);
            }
            builder.push(")");
            let rows: Vec<UserId> = builder
                .build_query_scalar()
                .fetch_all(&self.pool)
                .await
                .context("read pending members")?;
            out.extend(rows);
        }
        Ok(out)
    }

    /// Lets a pending member in. Answers whether they were waiting.
    pub async fn accept_rules(&self, user_id: UserId) -> anyhow::Result<bool> {
        let done = sqlx::query!("DELETE FROM pending_members WHERE user_id = ?", user_id)
            .execute(&self.pool)
            .await
            .context("accept rules")?;
        Ok(done.rows_affected() > 0)
    }

    /// Everything withheld from this member: a timeout, and the gate.
    pub(super) async fn member_deny(
        &self,
        user_id: UserId,
        channel: Option<ChannelId>,
    ) -> anyhow::Result<Permissions> {
        let gate = self.member_gate(user_id).await?.deny_in(channel);
        Ok(self.timeout_deny(user_id).await?.union(gate))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_member_loses_nothing() {
        assert_eq!(MemberGate::Member.deny_in(None), Permissions::NONE);
    }

    #[test]
    fn a_pending_member_keeps_only_view_in_the_rules_channel() {
        let rules = ChannelId::generate();
        let gate = MemberGate::Pending {
            rules_channel: Some(rules),
        };
        let left = Permissions::ALL.remove(gate.deny_in(Some(rules)));
        assert_eq!(left, Permissions::VIEW_CHANNEL);
        assert_eq!(gate.deny_in(Some(ChannelId::generate())), Permissions::ALL);
        assert_eq!(gate.deny_in(None), Permissions::ALL);
    }

    #[test]
    fn with_no_rules_channel_a_pending_member_sees_nothing() {
        let gate = MemberGate::Pending {
            rules_channel: None,
        };
        assert_eq!(gate.deny_in(Some(ChannelId::generate())), Permissions::ALL);
    }
}
