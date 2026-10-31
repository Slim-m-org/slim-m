<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0095 - Group DMs

Status: accepted
Date: 2026-10-28

## The ask

DMs are strictly two people.
A three or four person side conversation or call needs an admin to create a private channel and set permissions.
The owner put group DMs in v120.

## Decision

A group DM is a DM channel (kind `dm`) with 3 to 8 participants, recorded in `group_dm_members`.
A conversation between exactly two people stays the pair DM in `dm_channels`, unchanged: one channel per pair, opened by `POST /dms/{userId}`.
A group is never converted to a pair, and a pair never grows into a group; adding a person to a pair is starting a new group.

- **Why a table beside `dm_channels`, not a widened one.**
  `dm_channels` carries `UNIQUE(user_a, user_b)`, and that index is what makes opening a pair idempotent.
  Any number of groups may have the same members (as in Discord), so a group has no such key.
  Keeping the two apart leaves every pair code path, test and migration untouched.
- **Everything else is reused.**
  A group is a channel of kind `dm`, so messages, edits, search, sync, unread counts, push and calls take the DM path.
  Only the places that asked "who are the two accounts" now ask "who are the participants": the DM permission check (members only, `ADMINISTRATOR` included, exactly as for a pair), the batch check, the viewer filter, the DM list and the ring.
- **Size.**
  Creating takes the caller plus 2 to 7 others.
  A group holds at most 8 participants, counted including the caller.
  Past that, add is refused with a conflict.
- **Who can add.**
  Any current participant can add one account at a time.
  There is no owner and no moderation role: a group is a conversation, not a space.
  `KICK_MEMBERS` stays out of the DM permission set, so nobody removes anyone else; leaving is each person's own act.
- **Leaving.**
  A participant can leave at any time.
  The channel and its history stay for everyone who remains, and the leaver loses access to all of it, including the call.
  A group can shrink below 3.
  When the last participant leaves, the channel is deleted.
  A deleted account is removed from its groups the same way, so no group keeps naming a tombstone.
- **Blocks.**
  A group cannot be created with, and nobody can be added to, a set of people in which any pair has a block in either direction.
  The refusal says so in words the person can act on and does not say who blocked whom.
  A block made after the group exists does not remove anybody and does not change the group's permissions: the group is shared by people who did not block each other, and one pair's block must not silence a third person's conversation.
  The blocker keeps the tools they already have (client-side hiding of the blocked person's messages, push suppression, muting, leaving).
  A pair's block still evicts the blocked person from a shared pair call; it does not evict from a group call.
- **Naming.**
  The default name is derived by each client from the other participants' display names: "A, B and C", with more than three others shortened to "A, B and 3 others".
  Any participant can set a custom name (the same limits as a channel name) or clear it back to the default.
  The name is stored in `channels.name`; empty means the default.
  Nicknames resolve per viewer as they do for a pair, so the default name is never stored.
- **Ringing.**
  A call in a group rings every other participant.
  One ring per channel is still the rule.
  The first person to join answers it for everyone, which ends the ring on every other device.
  A decline only removes that person from the ring; the ring ends as declined when every callee has declined, and as timed out or canceled as before.
  Push is sent to each callee, with the same muting and foreground rules as a pair ring.
- **Fan-out.**
  Messages, ring frames and voice events already reach only accounts that pass `VIEW_CHANNEL` in the channel, which is the participant list.
  A new `dm.changed` event, delivered the same way, tells participants that the roster or the name moved so they re-read their DM list.
  It changes permissions, so it bumps the permission epoch.
  A person who has just left no longer passes the check and is told by the response to their own request instead.
- **Audit.**
  Group DMs write nothing to the admin audit log: the log records changes admins make to the space, and a DM is private to its participants, administrators included.
- **Creation is idempotent.**
  The client sends a UUIDv7 as the new channel's id; a replay by a participant returns the existing group.

## E2EE pre-wiring

No encryption changes now: group DMs are transport-encrypted like every DM.
The decision does not paint opt-in E2EE into a corner.
The participant list is an explicit, server-visible set of accounts with a `joined_at`, which is the membership a group key would be wrapped to.
`added_by` records who added each member, so a future signed-membership scheme has an author to bind to.
Membership changes already travel as their own event and never as a side effect of a message, so a later key rotation on add or leave has one place to hook.
Nothing about a group assumes the server can read the roster in the clear forever; it only assumes it today.

## Not in this decision

- No join or leave notice in the transcript yet; the roster change shows in the members sheet.
- No per-viewer hide for a group (a pair has one); leaving is the way to remove a group from the list.
- Cross-deployment group DMs stay out, as for pairs (0002).
