// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Group DMs (docs/decisions/0095): a DM channel with 3 to 8 participants.
//!
//! A pair stays in `dm_channels`; a group keeps its roster in
//! `group_dm_members` because any number of groups may share the same people.
//! Access is the roster and nothing else, `ADMINISTRATOR` included, which is
//! what [`Store::dm_permissions`] enforces for both shapes.

use std::collections::HashSet;

use sqlx::QueryBuilder;

use crate::ids::{ChannelId, UserId};

use super::dms::{DmConversation, GroupDm, new_dm_channel};
use super::{Channel, Store, User, now_ms};

/// Most participants a group holds, the creator included.
pub const GROUP_DM_MAX_PARTICIPANTS: usize = 8;

/// Fewest participants a new group starts with; two people use the pair DM.
pub const GROUP_DM_MIN_PARTICIPANTS: usize = 3;

/// Why a group DM operation was refused.
#[derive(Debug)]
pub enum GroupDmError {
    /// The group does not exist, or the caller is not in it.
    NotFound,
    /// An account named does not exist or has been deleted.
    UserNotFound,
    /// A block, in either direction, sits between two of the people involved.
    Blocked,
    /// A new group needs 2 to 7 others besides the caller.
    BadSize,
    /// The group already holds [`GROUP_DM_MAX_PARTICIPANTS`].
    Full,
    /// The account is already in the group.
    AlreadyMember,
    /// The client-chosen channel id belongs to something that is not the caller's group.
    IdTaken,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for GroupDmError {
    fn from(err: sqlx::Error) -> Self {
        GroupDmError::Internal(err.into())
    }
}

impl From<anyhow::Error> for GroupDmError {
    fn from(err: anyhow::Error) -> Self {
        GroupDmError::Internal(err)
    }
}

/// Where a group's channel row stands after [`Store::leave_group_dm`].
#[derive(Debug, PartialEq, Eq)]
pub enum LeftGroup {
    /// Others remain; the channel and its history stay for them.
    Remains,
    /// The caller was the last participant, so the channel was deleted.
    Deleted,
}

impl Store {
    /// Whether `user_id` is on the roster of the group DM `channel_id`.
    pub(crate) async fn is_group_dm_member(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<bool> {
        let row = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM group_dm_members WHERE channel_id = ? AND user_id = ?"#,
            channel_id,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    /// A group's roster, oldest member first, or empty if it is not a group.
    pub(crate) async fn group_dm_members(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Vec<UserId>> {
        let rows = sqlx::query_scalar!(
            r#"SELECT user_id AS "user_id!: UserId" FROM group_dm_members
               WHERE channel_id = ? ORDER BY joined_at, user_id"#,
            channel_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Everyone a DM channel (pair or group) belongs to, or `None` if it is not a DM.
    ///
    /// Exists so a caller with many candidates can narrow them first; see [`Store::viewers_among`].
    pub(crate) async fn dm_participants(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Option<Vec<UserId>>> {
        if let Some((a, b)) = self.dm_pair(channel_id).await? {
            return Ok(Some(if a == b { vec![a] } else { vec![a, b] }));
        }
        let members = self.group_dm_members(channel_id).await?;
        Ok((!members.is_empty()).then_some(members))
    }

    /// Whether any two of `people` have a block between them, in either direction.
    async fn any_block_among(&self, people: &[UserId]) -> anyhow::Result<bool> {
        for &person in people {
            if !self.blocked_among(person, people).await?.is_empty() {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Starts a group with `creator` and `others`, 3 to 8 people in all.
    ///
    /// `id` is the client's UUIDv7 for the new channel: a replay by a
    /// participant returns the group already made, and `created` says whether
    /// this call made it.
    pub async fn create_group_dm(
        &self,
        creator: UserId,
        others: &[UserId],
        name: Option<&str>,
        id: Option<ChannelId>,
    ) -> Result<(Channel, bool), GroupDmError> {
        if let Some(existing) = self.replayed_group(creator, id).await? {
            return Ok((existing, false));
        }
        let mut people = vec![creator];
        for &other in others {
            if !people.contains(&other) {
                people.push(other);
            }
        }
        if !(GROUP_DM_MIN_PARTICIPANTS..=GROUP_DM_MAX_PARTICIPANTS).contains(&people.len()) {
            return Err(GroupDmError::BadSize);
        }
        if self.user_profiles(&people).await?.len() != people.len() {
            return Err(GroupDmError::UserNotFound);
        }
        if self.any_block_among(&people).await? {
            return Err(GroupDmError::Blocked);
        }

        let channel_id = id.unwrap_or_else(ChannelId::generate);
        let name = name.unwrap_or("");
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "INSERT INTO channels (id, name, kind, created_at) VALUES (?, ?, 'dm', ?)",
            channel_id,
            name,
            now
        )
        .execute(&mut *tx)
        .await
        .map_err(|_| GroupDmError::IdTaken)?;
        sqlx::query!(
            "INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
             VALUES (?, 'message', 1), (?, 'canvas', 1)",
            channel_id,
            channel_id
        )
        .execute(&mut *tx)
        .await?;
        for &person in &people {
            let added_by = (person != creator).then_some(creator);
            sqlx::query!(
                "INSERT INTO group_dm_members (channel_id, user_id, added_by, joined_at)
                 VALUES (?, ?, ?, ?)",
                channel_id,
                person,
                added_by,
                now
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok((new_dm_channel(channel_id, name.to_owned(), now), true))
    }

    async fn replayed_group(
        &self,
        creator: UserId,
        id: Option<ChannelId>,
    ) -> Result<Option<Channel>, GroupDmError> {
        let Some(id) = id else { return Ok(None) };
        let Some(channel) = self.channel(id).await? else {
            return Ok(None);
        };
        if self.is_group_dm_member(creator, id).await? {
            Ok(Some(channel))
        } else {
            Err(GroupDmError::IdTaken)
        }
    }

    /// Adds `new_member` on `actor`'s behalf.
    ///
    /// Refused if any current member has a block with them, in either
    /// direction, so a person is never put in a room with someone they or
    /// that someone has blocked. The roster is read and written under one
    /// write lock, so two adds racing for the last seat cannot both land.
    pub async fn add_group_dm_member(
        &self,
        actor: UserId,
        channel_id: ChannelId,
        new_member: UserId,
    ) -> Result<(), GroupDmError> {
        if self.user_profile(new_member).await?.is_none() {
            return Err(GroupDmError::UserNotFound);
        }
        let mut tx = self.begin_write().await?;
        let members: Vec<UserId> = sqlx::query_scalar!(
            r#"SELECT user_id AS "user_id!: UserId" FROM group_dm_members g
               JOIN channels c ON c.id = g.channel_id AND c.deleted_at IS NULL
               WHERE g.channel_id = ?"#,
            channel_id
        )
        .fetch_all(&mut *tx)
        .await?;
        if !members.contains(&actor) {
            return Err(GroupDmError::NotFound);
        }
        if members.contains(&new_member) {
            return Err(GroupDmError::AlreadyMember);
        }
        if members.len() >= GROUP_DM_MAX_PARTICIPANTS {
            return Err(GroupDmError::Full);
        }
        let blockers = self.blockers_of(new_member).await?;
        if !self.blocked_among(new_member, &members).await?.is_empty()
            || members.iter().any(|member| blockers.contains(member))
        {
            return Err(GroupDmError::Blocked);
        }
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO group_dm_members (channel_id, user_id, added_by, joined_at)
             VALUES (?, ?, ?, ?)",
            channel_id,
            new_member,
            actor,
            now
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Takes `user_id` out of the group. The last one out deletes the channel.
    pub async fn leave_group_dm(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> Result<LeftGroup, GroupDmError> {
        let mut tx = self.begin_write().await?;
        let removed = sqlx::query!(
            "DELETE FROM group_dm_members WHERE channel_id = ? AND user_id = ?",
            channel_id,
            user_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if removed == 0 {
            return Err(GroupDmError::NotFound);
        }
        let left = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM group_dm_members WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_one(&mut *tx)
        .await?;
        let outcome = if left == 0 {
            let now = now_ms();
            sqlx::query!(
                "UPDATE channels SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                now,
                channel_id
            )
            .execute(&mut *tx)
            .await?;
            LeftGroup::Deleted
        } else {
            LeftGroup::Remains
        };
        tx.commit().await?;
        Ok(outcome)
    }

    /// Sets or clears (`None`) the group's custom name.
    pub async fn rename_group_dm(
        &self,
        actor: UserId,
        channel_id: ChannelId,
        name: Option<&str>,
    ) -> Result<(), GroupDmError> {
        let name = name.unwrap_or("");
        let renamed = sqlx::query!(
            "UPDATE channels SET name = ?
             WHERE id = ? AND deleted_at IS NULL
               AND EXISTS (SELECT 1 FROM group_dm_members
                           WHERE channel_id = channels.id AND user_id = ?)",
            name,
            channel_id,
            actor
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        match renamed {
            0 => Err(GroupDmError::NotFound),
            _ => Ok(()),
        }
    }

    /// The caller's conversation row for one group, as the DM list shows it.
    pub async fn group_dm_conversation(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> Result<DmConversation, GroupDmError> {
        self.list_group_conversations(user_id)
            .await?
            .into_iter()
            .find(|(_, conversation)| conversation.channel_id == channel_id)
            .map(|(_, conversation)| conversation)
            .ok_or(GroupDmError::NotFound)
    }

    /// The caller's groups with their rosters and unread counts, with each one's last activity.
    pub(super) async fn list_group_conversations(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Vec<(i64, DmConversation)>> {
        let rows = sqlx::query!(
            r#"SELECT g.channel_id AS "channel_id!: ChannelId",
                      c.created_at AS "created_at!",
                      c.name AS "name!",
                      COALESCE(
                          (SELECT m.created_at FROM messages m
                           WHERE m.channel_id = g.channel_id AND m.deleted_at IS NULL
                           ORDER BY m.seq DESC LIMIT 1),
                          c.created_at
                      ) AS "activity_at!: i64"
               FROM group_dm_members g
               JOIN channels c ON c.id = g.channel_id AND c.deleted_at IS NULL
               WHERE g.user_id = ?"#,
            user_id
        )
        .fetch_all(&self.pool)
        .await?;
        if rows.is_empty() {
            return Ok(Vec::new());
        }

        let channel_ids: Vec<ChannelId> = rows.iter().map(|row| row.channel_id).collect();
        let rosters = self.group_rosters(&channel_ids).await?;
        let everyone: Vec<UserId> = rosters.iter().map(|(_, user)| *user).collect();
        let profiles: std::collections::HashMap<UserId, User> = self
            .user_profiles(&everyone)
            .await?
            .into_iter()
            .map(|user| (user.id, user))
            .collect();
        let unread = self.unread_counts(user_id, &channel_ids).await?;

        let mut conversations = Vec::with_capacity(rows.len());
        for row in rows {
            let members: Vec<User> = rosters
                .iter()
                .filter(|(channel, _)| *channel == row.channel_id)
                .filter_map(|(_, member)| profiles.get(member).cloned())
                .collect();
            let Some(other) = members
                .iter()
                .find(|member| member.id != user_id)
                .or(members.first())
                .cloned()
            else {
                continue;
            };
            conversations.push((
                row.activity_at,
                DmConversation {
                    channel_id: row.channel_id,
                    other,
                    unread: unread.get(&row.channel_id).copied().unwrap_or(0),
                    created_at: row.created_at,
                    group: Some(GroupDm {
                        name: (!row.name.is_empty()).then_some(row.name),
                        members,
                    }),
                },
            ));
        }
        Ok(conversations)
    }

    /// `(channel, member)` for every roster row of `channel_ids`, oldest member first.
    async fn group_rosters(
        &self,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<Vec<(ChannelId, UserId)>> {
        use sqlx::Row;
        let mut rosters = Vec::new();
        for chunk in channel_ids.chunks(super::MAX_IDS_PER_QUERY) {
            let mut builder = QueryBuilder::new(
                "SELECT channel_id, user_id FROM group_dm_members WHERE channel_id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(") ORDER BY joined_at, user_id");
            for row in builder.build().fetch_all(&self.pool).await? {
                rosters.push((row.try_get("channel_id")?, row.try_get("user_id")?));
            }
        }
        Ok(rosters)
    }

    /// Which of `channel_ids` are groups `user_id` belongs to.
    pub(super) async fn group_memberships_among(
        &self,
        user_id: UserId,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<HashSet<ChannelId>> {
        use sqlx::Row;
        let mut found = HashSet::new();
        for chunk in channel_ids.chunks(super::MAX_IDS_PER_QUERY - 1) {
            let mut builder =
                QueryBuilder::new("SELECT channel_id FROM group_dm_members WHERE user_id = ");
            builder.push_bind(user_id);
            builder.push(" AND channel_id IN (");
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                found.insert(row.try_get("channel_id")?);
            }
        }
        Ok(found)
    }

    /// Removes a deleted account from every group it was in, deleting any left empty.
    pub(super) async fn leave_all_group_dms(
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        user_id: UserId,
    ) -> anyhow::Result<()> {
        let groups: Vec<ChannelId> = sqlx::query_scalar!(
            r#"SELECT channel_id AS "channel_id!: ChannelId" FROM group_dm_members WHERE user_id = ?"#,
            user_id
        )
        .fetch_all(&mut **tx)
        .await?;
        sqlx::query!("DELETE FROM group_dm_members WHERE user_id = ?", user_id)
            .execute(&mut **tx)
            .await?;
        // Who added the others stays as a fact about them, minus the name of the person now gone.
        sqlx::query!(
            "UPDATE group_dm_members SET added_by = NULL WHERE added_by = ?",
            user_id
        )
        .execute(&mut **tx)
        .await?;
        let now = now_ms();
        for channel_id in groups {
            sqlx::query!(
                "UPDATE channels SET deleted_at = ?
                 WHERE id = ? AND deleted_at IS NULL
                   AND NOT EXISTS (SELECT 1 FROM group_dm_members WHERE channel_id = channels.id)",
                now,
                channel_id
            )
            .execute(&mut **tx)
            .await?;
        }
        Ok(())
    }
}
