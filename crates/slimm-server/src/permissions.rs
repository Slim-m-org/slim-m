// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The deny-by-default permission model and its evaluator.
//!
//! A permission set is a bitmask stored in a 63-bit `INTEGER`. Nothing is
//! granted implicitly: a user can only do what the evaluated set contains.
//!
//! [`evaluate`] resolves the effective set for a user in a channel, in this
//! fixed order:
//!
//! 1. Base. The `@everyone` role's permissions, then the union of every role the
//!    user holds.
//! 2. Administrator bypass. If the base set carries [`Permissions::ADMINISTRATOR`]
//!    the user gets everything and channel overwrites are skipped entirely.
//! 3. The `@everyone` channel overwrite: clear its deny bits, then set its allow.
//! 4. The role channel overwrites, aggregated across the user's roles with deny
//!    winning: set the union of allows, then clear the union of denies.
//! 5. The member channel overwrite, which is absolute and has the final say:
//!    clear its deny bits, then set its allow.
//!
//! Step 4 deviates from the allow-wins convention some platforms use: here a
//! deny on any of the user's roles wins over an allow on another, which is the
//! more conservative reading and matches the project's deny-by-default stance.
//! The member overwrite in step 5 is what re-grants a permission to a specific
//! user despite a role-level deny.

/// A set of permission bits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, sqlx::Type)]
#[sqlx(transparent)]
pub struct Permissions(i64);

impl Permissions {
    /// No permissions. The starting point for every evaluation.
    pub const NONE: Self = Self(0);

    /// Grants every permission and bypasses all channel overwrites.
    pub const ADMINISTRATOR: Self = Self(1 << 0);
    /// See a channel and its history.
    pub const VIEW_CHANNEL: Self = Self(1 << 1);
    /// Post messages in a channel.
    pub const SEND_MESSAGES: Self = Self(1 << 2);
    /// Edit or delete other members' messages.
    pub const MANAGE_MESSAGES: Self = Self(1 << 3);
    /// Create, edit, and delete channels.
    pub const MANAGE_CHANNELS: Self = Self(1 << 4);
    /// Create, edit, and delete roles and their assignments.
    pub const MANAGE_ROLES: Self = Self(1 << 5);
    /// Remove members from the community.
    pub const KICK_MEMBERS: Self = Self(1 << 6);
    /// Ban members from the community.
    pub const BAN_MEMBERS: Self = Self(1 << 7);
    /// Create invites.
    pub const CREATE_INVITE: Self = Self(1 << 8);
    /// Add reactions to messages.
    pub const ADD_REACTIONS: Self = Self(1 << 9);
    /// Attach files to messages.
    pub const ATTACH_FILES: Self = Self(1 << 10);
    /// Join a voice channel.
    pub const CONNECT: Self = Self(1 << 11);
    /// Transmit audio in a voice channel.
    pub const SPEAK: Self = Self(1 << 12);
    /// View and draw on the voice canvas.
    pub const USE_CANVAS: Self = Self(1 << 13);
    /// Moderate canvas objects (move or remove others' work).
    pub const MANAGE_CANVAS: Self = Self(1 << 14);
    /// Change community-wide settings.
    pub const MANAGE_SERVER: Self = Self(1 << 15);
    /// Have an `@everyone` or `@here` mention actually wake anyone, rather
    /// than sit as plain text nobody is pushed for. See
    /// `push::recipients::resolved_mentions`, the one place this is read;
    /// `@everyone`/`@here` remain typeable without it, they just reach
    /// nobody extra, the same forgiving shape an unmatched `@nobody` has.
    pub const MENTION_EVERYONE: Self = Self(1 << 16);
    /// Run a fenced code block through this deployment's configured code
    /// runner (`crate::code_runner`), when one is configured at all.
    /// Defaults to nobody, deliberately: `USE_CANVAS` shipping to
    /// `@everyone` with no removal path is this repository's own cautionary
    /// example, and running arbitrary code is a larger ask than drawing on a
    /// canvas. Evaluated per channel for the message-scoped run route and at
    /// the base (guild) level for the two routes with no channel of their
    /// own - see `http::module_commands`'s own doc.
    pub const RUN_CODE: Self = Self(1 << 17);
    /// Read `/reports/history` without `MANAGE_MESSAGES`'s power to act on a
    /// report or delete a message. Deployment-wide, not per-channel; see
    /// `docs/decisions/0028-bot-accounts.md`.
    pub const VIEW_MODERATION_HISTORY: Self = Self(1 << 18);
    /// Move a participant from one voice call to another; needed in both
    /// channels. See `docs/decisions/0071-move-members.md`.
    pub const MOVE_MEMBERS: Self = Self(1 << 19);

    /// The union of every defined permission. What administrator resolves to.
    pub const ALL: Self = Self(
        Self::ADMINISTRATOR.0
            | Self::VIEW_CHANNEL.0
            | Self::SEND_MESSAGES.0
            | Self::MANAGE_MESSAGES.0
            | Self::MANAGE_CHANNELS.0
            | Self::MANAGE_ROLES.0
            | Self::KICK_MEMBERS.0
            | Self::BAN_MEMBERS.0
            | Self::CREATE_INVITE.0
            | Self::ADD_REACTIONS.0
            | Self::ATTACH_FILES.0
            | Self::CONNECT.0
            | Self::SPEAK.0
            | Self::USE_CANVAS.0
            | Self::MANAGE_CANVAS.0
            | Self::MANAGE_SERVER.0
            | Self::MENTION_EVERYONE.0
            | Self::RUN_CODE.0
            | Self::VIEW_MODERATION_HISTORY.0
            | Self::MOVE_MEMBERS.0,
    );

    /// Wraps a raw bitmask, for example one loaded from the database.
    pub const fn from_bits(bits: i64) -> Self {
        Self(bits)
    }

    /// The raw bitmask, for storage or the wire.
    pub const fn bits(self) -> i64 {
        self.0
    }

    /// Whether every bit in `other` is present.
    pub const fn contains(self, other: Self) -> bool {
        (self.0 & other.0) == other.0
    }

    /// Whether any bit in `other` is present.
    pub const fn intersects(self, other: Self) -> bool {
        (self.0 & other.0) != 0
    }

    /// The union of two sets.
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    /// This set with `other`'s bits cleared.
    pub const fn remove(self, other: Self) -> Self {
        Self(self.0 & !other.0)
    }
}

/// A channel overwrite: bits to force on (`allow`) and bits to force off
/// (`deny`) for one role or one member.
#[derive(Debug, Clone, Copy)]
pub struct Overwrite {
    pub allow: Permissions,
    pub deny: Permissions,
}

/// Resolves the effective permissions for a user in a channel. See the module
/// docs for the precedence rules. Pass `None`/empty for a guild-level (no
/// channel) evaluation.
pub fn evaluate(
    everyone: Permissions,
    member_roles: &[Permissions],
    everyone_overwrite: Option<Overwrite>,
    role_overwrites: &[Overwrite],
    member_overwrite: Option<Overwrite>,
) -> Permissions {
    let mut base = everyone;
    for role in member_roles {
        base = base.union(*role);
    }

    if base.contains(Permissions::ADMINISTRATOR) {
        return Permissions::ALL;
    }

    if let Some(ow) = everyone_overwrite {
        base = base.remove(ow.deny).union(ow.allow);
    }

    let mut allow = Permissions::NONE;
    let mut deny = Permissions::NONE;
    for ow in role_overwrites {
        allow = allow.union(ow.allow);
        deny = deny.union(ow.deny);
    }
    base = base.union(allow).remove(deny);

    if let Some(ow) = member_overwrite {
        base = base.remove(ow.deny).union(ow.allow);
    }

    base
}

/// Masks a bitmask to all-zero unless it carries VIEW_CHANNEL.
///
/// A real channel the caller cannot view still passes its unrelated base
/// bits straight through unless an overwrite happens to deny them, and
/// `@everyone` usually grants something - so left unmasked, this would
/// answer differently for "channel does not exist" (forced NONE) than for
/// "channel exists, caller cannot view it, but nothing denies the bits
/// their base already grants", turning a caller into a channel-existence
/// oracle. Shared by `GET /channels/{channelId}/permissions` and
/// `Store::permissions_in_channels`; see
/// docs/decisions/0011-per-channel-permissions.md.
pub fn mask_unless_viewable(permissions: Permissions) -> Permissions {
    if permissions.contains(Permissions::VIEW_CHANNEL) {
        permissions
    } else {
        Permissions::NONE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VIEW: Permissions = Permissions::VIEW_CHANNEL;
    const SEND: Permissions = Permissions::SEND_MESSAGES;

    fn allow(p: Permissions) -> Overwrite {
        Overwrite {
            allow: p,
            deny: Permissions::NONE,
        }
    }

    fn deny(p: Permissions) -> Overwrite {
        Overwrite {
            allow: Permissions::NONE,
            deny: p,
        }
    }

    /// The masking that stops a channel being an existence oracle (decision
    /// 0011): without VIEW_CHANNEL every other bit is hidden, so a caller who
    /// cannot see the channel cannot read one permission off it; with it, the
    /// set passes through unchanged.
    #[test]
    fn mask_unless_viewable_hides_everything_without_view() {
        // A rich set still collapses to nothing when VIEW_CHANNEL is absent.
        let rich = SEND.union(Permissions::MANAGE_MESSAGES);
        assert_eq!(mask_unless_viewable(rich), Permissions::NONE);
        assert_eq!(mask_unless_viewable(Permissions::NONE), Permissions::NONE);
        // With VIEW_CHANNEL present, the whole set is visible unchanged.
        let viewable = VIEW.union(SEND);
        assert_eq!(mask_unless_viewable(viewable), viewable);
        assert_eq!(mask_unless_viewable(VIEW), VIEW);
    }

    #[test]
    fn nothing_is_granted_by_default() {
        let result = evaluate(Permissions::NONE, &[], None, &[], None);
        assert_eq!(result, Permissions::NONE);
        assert!(!result.contains(SEND));
    }

    #[test]
    fn everyone_base_and_role_union_accumulate() {
        let everyone = VIEW.union(SEND);
        let mod_role = Permissions::MANAGE_MESSAGES;
        let result = evaluate(everyone, &[mod_role], None, &[], None);
        assert!(result.contains(VIEW));
        assert!(result.contains(SEND));
        assert!(result.contains(Permissions::MANAGE_MESSAGES));
    }

    #[test]
    fn administrator_grants_all_and_ignores_denies() {
        let admin = Permissions::ADMINISTRATOR;
        // Even a member overwrite denying everything cannot touch an admin.
        let result = evaluate(
            Permissions::NONE,
            &[admin],
            None,
            &[deny(Permissions::ALL)],
            Some(deny(Permissions::ALL)),
        );
        assert_eq!(result, Permissions::ALL);
        assert!(result.contains(Permissions::BAN_MEMBERS));
    }

    #[test]
    fn everyone_overwrite_can_remove_a_base_permission() {
        let everyone = VIEW.union(SEND);
        let result = evaluate(everyone, &[], Some(deny(SEND)), &[], None);
        assert!(result.contains(VIEW));
        assert!(!result.contains(SEND));
    }

    #[test]
    fn role_overwrite_deny_wins_over_role_overwrite_allow() {
        // One role's overwrite allows SEND, another denies it. Deny wins.
        let everyone = VIEW;
        let result = evaluate(everyone, &[], None, &[allow(SEND), deny(SEND)], None);
        assert!(result.contains(VIEW));
        assert!(
            !result.contains(SEND),
            "a role-level deny wins over an allow"
        );
    }

    #[test]
    fn member_overwrite_regrants_over_a_role_deny() {
        // Role tier denies SEND; the member overwrite grants it back absolutely.
        let everyone = VIEW;
        let result = evaluate(everyone, &[], None, &[deny(SEND)], Some(allow(SEND)));
        assert!(result.contains(SEND), "member overwrite is absolute");
    }

    #[test]
    fn member_overwrite_deny_removes_a_granted_permission() {
        let everyone = VIEW.union(SEND);
        let result = evaluate(everyone, &[], None, &[], Some(deny(SEND)));
        assert!(result.contains(VIEW));
        assert!(!result.contains(SEND));
    }

    /// A bit omitted from `ALL` is a bit administrators do not hold, that the
    /// API refuses to grant, and that nothing else here would catch.
    #[test]
    fn all_is_the_union_of_every_named_permission() {
        let named = [
            Permissions::ADMINISTRATOR,
            Permissions::VIEW_CHANNEL,
            Permissions::SEND_MESSAGES,
            Permissions::MANAGE_MESSAGES,
            Permissions::MANAGE_CHANNELS,
            Permissions::MANAGE_ROLES,
            Permissions::KICK_MEMBERS,
            Permissions::BAN_MEMBERS,
            Permissions::CREATE_INVITE,
            Permissions::ADD_REACTIONS,
            Permissions::ATTACH_FILES,
            Permissions::CONNECT,
            Permissions::SPEAK,
            Permissions::USE_CANVAS,
            Permissions::MANAGE_CANVAS,
            Permissions::MANAGE_SERVER,
            Permissions::MENTION_EVERYONE,
            Permissions::RUN_CODE,
            Permissions::VIEW_MODERATION_HISTORY,
            Permissions::MOVE_MEMBERS,
        ];
        let union = named
            .into_iter()
            .fold(Permissions::NONE, Permissions::union);
        assert_eq!(union, Permissions::ALL);
    }

    #[test]
    fn contains_and_intersects_are_distinct() {
        let set = VIEW.union(SEND);
        assert!(set.contains(VIEW));
        assert!(set.contains(VIEW.union(SEND)));
        assert!(!set.contains(VIEW.union(Permissions::BAN_MEMBERS)));
        assert!(set.intersects(VIEW.union(Permissions::BAN_MEMBERS)));
        assert!(!set.intersects(Permissions::BAN_MEMBERS));
    }
}
