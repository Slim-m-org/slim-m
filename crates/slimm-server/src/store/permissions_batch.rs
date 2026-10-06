// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The batched permission read paths: many candidates against one channel
//! (push fan-out), many channels against one caller (the rail listing and
//! `GET /channels`'s own bitmask), and many arbitrary channel ids against
//! one caller (the report queue's `channel_permissions` field).
//!
//! Split from `permissions.rs` when the batching pushed that file past the
//! 500-line ceiling. All three load a role context and a set of overwrites
//! with a bounded number of queries, then run the same pure
//! [`crate::permissions::evaluate`] the per-user path runs, and each carries
//! an equivalence test in `tests/permissions.rs` proving the answers
//! identical to asking the per-user path once per candidate.

use uuid::Uuid;

use super::Store;
use super::permissions::{ChannelOverwrite, RoleContext};
use super::timeouts::TIMEOUT_DENY;
use crate::ids::{ChannelId, UserId};
use crate::permissions::{Permissions, evaluate, mask_unless_viewable};

impl Store {
    /// Which of `candidates` hold VIEW_CHANNEL in `channel_id`, answered with
    /// a bounded number of queries instead of a full evaluation per candidate.
    ///
    /// Push fan-out asked [`Self::has_permission`] once per push-registered
    /// user on every message, and each ask is its own channel fetch, two role
    /// queries and an overwrite fetch; on a busy channel that multiplied the
    /// per-message write-path work by the member count. This loads the
    /// channel, the @everyone role, every candidate's roles and the channel's
    /// overwrites once each, then runs the same pure [`evaluate`] per
    /// candidate, so the answers are identical by construction.
    ///
    /// A DM never reaches the evaluator, mirroring
    /// [`Self::permissions_in_channel`]. Its pair is fetched once here and the
    /// candidates are narrowed to it before anything else is asked, so the
    /// candidate count stops mattering on that branch too.
    ///
    /// It did not, until 2026-07-30. This doc comment and the one inside the
    /// branch both claimed the loop was bounded at two real checks while it ran
    /// `dm_permissions` - itself a `dm_channels` lookup plus up to two block
    /// lookups - once per candidate. The cost was negligible in practice, since
    /// the candidates are a self-host's push-registered users, which is exactly
    /// why nothing caught it; a comment stating a bound that is not there is
    /// worse than no comment, because the next reader believes it and looks
    /// somewhere else.
    pub async fn viewers_among(
        &self,
        channel_id: ChannelId,
        candidates: &[UserId],
    ) -> anyhow::Result<Vec<UserId>> {
        if candidates.is_empty() {
            return Ok(Vec::new());
        }
        let Some(channel) = self.channel(channel_id).await? else {
            return Ok(Vec::new());
        };
        // A thread has no overwrites of its own; see `permission_channel`.
        let Some(channel) = self.permission_channel(channel).await? else {
            return Ok(Vec::new());
        };
        let channel_id = channel.id;

        // One query: asking per candidate restores the cost this function removes.
        let timed_out = self.timed_out_among_until(candidates).await?;
        let deny_for = |user_id: UserId| {
            if timed_out.contains_key(&user_id) {
                TIMEOUT_DENY
            } else {
                Permissions::NONE
            }
        };

        if channel.kind == super::dms::DM_CHANNEL_KIND {
            let Some((user_a, user_b)) = self.dm_pair(channel_id).await? else {
                return Ok(Vec::new());
            };
            let mut viewers = Vec::new();
            // Narrowed to the pair first, so this really is at most two checks.
            for &user_id in candidates {
                if user_id != user_a && user_id != user_b {
                    continue;
                }
                if self
                    .dm_permissions(user_id, channel_id)
                    .await?
                    .remove(deny_for(user_id))
                    .contains(Permissions::VIEW_CHANNEL)
                {
                    viewers.push(user_id);
                }
            }
            return Ok(viewers);
        }

        let (everyone_id, everyone_perms) = self.everyone_role().await?;

        // One built query for every candidate's roles (no array binding in SQLite), the same shape roles_for_users uses.
        // Joined from `users` so a webhook candidate is recognised without a second round trip.
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT u.id AS user_id, u.is_webhook AS is_webhook, \
                    r.id AS role_id, r.permissions AS permissions \
             FROM users u \
             LEFT JOIN member_roles mr ON mr.user_id = u.id \
             LEFT JOIN roles r ON r.id = mr.role_id AND r.is_everyone = 0 \
             WHERE u.id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in candidates {
            separated.push_bind(*id);
        }
        builder.push(")");
        let role_rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        use std::collections::HashMap;
        let mut contexts: HashMap<Uuid, RoleContext> = HashMap::new();
        for row in role_rows {
            let user_id: Uuid = row.try_get("user_id")?;
            let context = contexts.entry(user_id).or_insert_with(|| RoleContext {
                everyone_id,
                everyone_perms,
                ..RoleContext::none()
            });
            // A webhook holds no roles at all, `@everyone` included; see `load_roles`.
            if row.try_get::<i64, _>("is_webhook")? != 0 {
                *context = RoleContext::none();
                continue;
            }
            if let Some(role_id) = row.try_get::<Option<Uuid>, _>("role_id")? {
                context.role_ids.push(role_id);
                context.role_perms.push(row.try_get("permissions")?);
            }
        }

        let overwrites = self.channel_overwrites(channel_id).await?;
        let unknown = RoleContext {
            everyone_id,
            everyone_perms,
            ..RoleContext::none()
        };
        let mut viewers = Vec::new();
        for &user_id in candidates {
            let context = contexts.get(&user_id.0).unwrap_or(&unknown);
            let perms = context
                .evaluate_for(user_id, &overwrites)
                .permissions
                .remove(deny_for(user_id));
            if perms.contains(Permissions::VIEW_CHANNEL) {
                viewers.push(user_id);
            }
        }
        Ok(viewers)
    }

    /// The channels this user can view, in rail order.
    pub async fn visible_channels(&self, user_id: UserId) -> anyhow::Result<Vec<super::Channel>> {
        self.channels_where(user_id, Permissions::VIEW_CHANNEL)
            .await
    }

    /// [`Self::visible_channels`], paired with each channel's own full
    /// effective bitmask - what `GET /channels`'s `permissions` field is
    /// populated from - and whether `@everyone` itself lacks VIEW_CHANNEL
    /// there, what that response's `restricted` field is populated from.
    /// Every row here already carries VIEW_CHANNEL by construction (this
    /// filters on exactly that bit, and every row came from
    /// [`Self::list_channels`] in the first place), so unlike the dedicated
    /// per-channel route and [`Self::permissions_in_channels`] below, there
    /// is no "channel does not exist" case a raw answer could be confused
    /// with, and nothing here needs [`crate::permissions::mask_unless_viewable`].
    pub async fn visible_channels_with_permissions(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Vec<(super::Channel, Permissions, bool)>> {
        Ok(self
            .channel_permissions_all(user_id)
            .await?
            .into_iter()
            .filter(|(_, perms, _)| perms.contains(Permissions::VIEW_CHANNEL))
            .collect())
    }

    /// [`Store::list_channels`] filtered by `needed`, with the caller's role
    /// context loaded once. DMs and deleted channels are outside it, because
    /// they are outside `list_channels`.
    ///
    /// The rail handler used to ask [`Self::has_permission`] per channel, which
    /// re-fetched the channel row it already held and the same role context
    /// every iteration - 1 + 4C queries for C channels on a request every
    /// client fires at startup. This is four queries however many channels
    /// exist, evaluated by the same pure [`evaluate`]. The moderation queue
    /// asks the same question about MANAGE_MESSAGES, which is why the
    /// permission is a parameter rather than the VIEW_CHANNEL this started as.
    pub async fn channels_where(
        &self,
        user_id: UserId,
        needed: Permissions,
    ) -> anyhow::Result<Vec<super::Channel>> {
        Ok(self
            .channel_permissions_all(user_id)
            .await?
            .into_iter()
            .filter(|(_, perms, _)| perms.contains(needed))
            .map(|(channel, _, _)| channel)
            .collect())
    }

    /// The shared load-and-evaluate behind [`Self::channels_where`] and
    /// [`Self::visible_channels_with_permissions`]: every live channel's row
    /// paired with the caller's full effective bitmask in it and whether the
    /// channel is restricted, unfiltered. Both callers trim this to their own
    /// shape, so the query cost - one `load_roles` call and one batched
    /// overwrite fetch for however many channels exist - is paid once
    /// regardless of which is asked; this used to be `channels_where`'s own
    /// body before a second caller needed the bitmask itself rather than only
    /// a bool.
    ///
    /// "Restricted" is answered from the same per-channel `everyone_overwrite`
    /// this loop already isolates out of the shared overwrite fetch to build
    /// the caller's own bitmask, run back through [`evaluate`] with no roles
    /// and no member overwrite of any kind - `@everyone`'s own view of the
    /// channel, which is the same for every caller by construction. No new
    /// query and no new row: it is one extra CPU-only `evaluate` call per
    /// channel already being evaluated once for the caller's own bitmask.
    async fn channel_permissions_all(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Vec<(super::Channel, Permissions, bool)>> {
        let channels = self.list_channels().await?;
        if channels.is_empty() {
            return Ok(Vec::new());
        }
        let roles = self.load_roles(user_id).await?;
        // Hoisted: the map closure below is synchronous and cannot await.
        let timeout_deny = self.timeout_deny(user_id).await?;

        let by_channel = self
            .overwrites_by_channel(channels.iter().map(|channel| channel.id))
            .await?;

        let empty = Vec::new();
        Ok(channels
            .into_iter()
            .map(|channel| {
                let overwrites = by_channel.get(&channel.id.0).unwrap_or(&empty);
                let evaluated = roles.evaluate_for(user_id, overwrites);
                let perms = evaluated.permissions.remove(timeout_deny);
                let restricted = !evaluate(
                    roles.everyone_perms,
                    &[],
                    evaluated.everyone_overwrite,
                    &[],
                    None,
                )
                .contains(Permissions::VIEW_CHANNEL);
                (channel, perms, restricted)
            })
            .collect())
    }

    /// Every overwrite on `channel_ids` in one built query (no array binding
    /// in SQLite), grouped by channel.
    async fn overwrites_by_channel(
        &self,
        channel_ids: impl Iterator<Item = ChannelId>,
    ) -> anyhow::Result<std::collections::HashMap<Uuid, Vec<ChannelOverwrite>>> {
        use sqlx::Row;
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT channel_id, target_type, target_id, allow, deny \
             FROM channel_overwrites WHERE channel_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in channel_ids {
            separated.push_bind(id);
        }
        builder.push(")");

        let mut by_channel: std::collections::HashMap<Uuid, Vec<ChannelOverwrite>> =
            std::collections::HashMap::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            by_channel
                .entry(row.try_get("channel_id")?)
                .or_default()
                .push(ChannelOverwrite {
                    target_type: row.try_get("target_type")?,
                    target_id: row.try_get("target_id")?,
                    allow: row.try_get("allow")?,
                    deny: row.try_get("deny")?,
                });
        }
        Ok(by_channel)
    }

    /// The caller's effective permissions in each of `channel_ids`, batched
    /// so a report page costs one shared query rather than one
    /// [`Self::permissions_in_channel`] call per report.
    ///
    /// Unlike [`Self::channels_where`], this does not start from
    /// [`Self::list_channels`] - it answers for exactly the ids it is asked
    /// about, which is what lets it reach a DM or a deleted channel:
    /// `list_channels` excludes both by construction (see
    /// docs/decisions/0005-threads.md), and those are precisely the two
    /// report cases docs/decisions/0011-per-channel-permissions.md names as
    /// needing this. Each id resolves independently: a thread through
    /// [`Self::permission_channel`], a DM through [`Self::dm_permissions`], a
    /// dead or nonexistent id to [`Permissions::NONE`], and everything else
    /// through the ordinary evaluator - sharing one [`Self::load_roles`] call
    /// and one `IN`-batched overwrite fetch across however many ordinary
    /// channels the page names. Masked with
    /// [`crate::permissions::mask_unless_viewable`], the same guard
    /// `http::channel_permissions` applies to its own answer and for the
    /// identical existence-probe reason.
    ///
    /// Query cost is bounded independently of how long the id list is, which
    /// matters because `may_link` hands this every channel that has ever
    /// attached one sha256 - a widely forwarded image, on the message-send
    /// path. Per call: one `timeout_deny`, one `load_roles`, at most three
    /// rounds in [`Self::resolve_permission_channels`], one
    /// [`Self::dm_permissions_batch`] (a pair query plus two block reads) if
    /// any id is a DM, and one
    /// batched overwrite query for the rest. It was a `channel` fetch per
    /// distinct id plus a `dm_permissions` call per distinct DM until this was
    /// batched; the doc comment recording that cost is what made it findable.
    pub async fn permissions_in_channels(
        &self,
        user_id: UserId,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<std::collections::HashMap<ChannelId, Permissions>> {
        use std::collections::HashMap;

        let mut result: HashMap<ChannelId, Permissions> = HashMap::new();
        if channel_ids.is_empty() {
            return Ok(result);
        }

        let timeout_deny = self.timeout_deny(user_id).await?;
        let roles = self.load_roles(user_id).await?;

        let resolved = self.resolve_permission_channels(channel_ids).await?;
        for channel_id in resolved.dead {
            result.insert(channel_id, Permissions::NONE);
        }
        if !resolved.dms.is_empty() {
            let mut dm_ids: Vec<ChannelId> = resolved.dms.iter().map(|(_, dm)| *dm).collect();
            dm_ids.sort();
            dm_ids.dedup();
            let dm_permissions = self.dm_permissions_batch(user_id, &dm_ids).await?;
            for (requested_id, dm_id) in resolved.dms {
                let permissions = dm_permissions
                    .get(&dm_id)
                    .copied()
                    .unwrap_or(Permissions::NONE)
                    .remove(timeout_deny);
                result.insert(requested_id, mask_unless_viewable(permissions));
            }
        }

        let ordinary = resolved.ordinary;
        if ordinary.is_empty() {
            return Ok(result);
        }

        // Deduplicated, since several requested ids can resolve to one channel.
        let mut resolved_ids: Vec<ChannelId> = ordinary.iter().map(|(_, c)| c.id).collect();
        resolved_ids.sort_by_key(|id| id.0);
        resolved_ids.dedup();
        let by_channel = self.overwrites_by_channel(resolved_ids.into_iter()).await?;

        let empty = Vec::new();
        for (requested_id, channel) in ordinary {
            let overwrites = by_channel.get(&channel.id.0).unwrap_or(&empty);
            let perms = roles
                .evaluate_for(user_id, overwrites)
                .permissions
                .remove(timeout_deny);
            result.insert(requested_id, mask_unless_viewable(perms));
        }

        Ok(result)
    }
}
