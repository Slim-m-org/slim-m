# 0092 - Server hardening review answers

Status: accepted
Date: 2026-10-26
Extends: 0048 (TOTP two-factor)

## Why this exists

The server hardening review (PR 1571) raised seven questions that needed an owner call.
This record holds the owner's answer to each, with the reasoning.

## Changed

### Peer moderation is refused (question 3)

The owner chose to make equal-rank peers off limits.
A moderator can no longer kick, remove, time out or rename a member whose granted permissions equal their own.
The reasoning is that two people with the same powers should not be able to silence each other.
An administrator is exempt, because their grant contains every bit and nobody ranks above them.
Role management and voice kicks keep the original containment rule.
The refusal is a 403 with the reason `you cannot act on someone of equal rank`.

Replaced on 2026-11-16 by the role ladder below: equal rank is now read from role position, not from equal permission bits.

### Changing the TOTP policy needs the admin's own factor (question 5)

The owner chose to require the acting admin to have a confirmed second factor before they change the TOTP policy.
The reasoning is that an admin who turns the policy on without a factor locks themselves out of every admin route until they enrol.
Bots are exempt, as they are everywhere else the policy is enforced.
A request that leaves the policy at its current value is not affected.
The refusal is a 403 with the reason `turn on two-factor sign-in on your own account before changing the two-factor policy`.

## Accepted as current behaviour

### Forwarded message origin ids (question 1)

A forwarded message keeps the origin channel id and message id, even for a channel the reader cannot see.
The reasoning is that the ids are random UUIDs that grant no access, and hiding them per reader adds a code path for little value.

### Familiar devices (question 2)

The sign-in alert keeps testing the client-supplied device name and client kind.
The reasoning is that the alert is a hint to the account owner, not a gate, and a server-side fingerprint would add tracking for the same hint.

### Moderators in the TOTP policy scope (question 4)

Enforcement of `required_for_elevated` stays on ADMINISTRATOR only, as decision 0048 says.
The reasoning is that moderators cannot reach settings or account recovery, and widening the scope would lock out moderators who have not enrolled.
The settings copy should say "administrators" and not imply moderators.

### Retry-After on 429s (question 6)

The TOTP-locked and ephemeral-budget 429s keep sending no Retry-After header.
The locked response already carries an `until` value, and the client shows its own wait wording.

### A code for the second-factor 403 (question 7)

The second-factor 403 keeps its message as the only signal.
The client matches the message for the refusals above and shows a plain sentence, so no wire code is added for now.

## The role ladder and the Space owner (owner decision, 2026-11-16)

Roles and moderation now follow Discord's hierarchy.
This replaces the peer rule above and the administrator exemptions of the role reorder and voice kick rank checks.

### The ladder

A member stands at their highest role's position; a member holding no role stands below every role, as `@everyone` does.
A caller may grant, revoke, edit, reorder or delete only a role strictly below where they stand; `@everyone` is below every role, so anyone who manages roles may edit it.
No two roles share a position.
A new role, a bot's own role and the shared Bots role enter at the bottom, just above `@everyone`, and lift every other role one step, as on Discord.
So a caller who holds any role may create one, and one who holds none cannot.
A reorder keeps every role at or above the caller's highest where it is, ties and gaps included, and renumbers only the roles below it, so a gap left by a deleted role never locks a manager out.
Migration 0198 numbered the roles of an existing deployment, which had all taken position 0 before the ladder gave position a meaning, in the order the roles list showed them (oldest first among a tie).
A bot that manages roles can therefore land below a role it should grant; the owner fixes that with one drag in Roles.
A caller may kick from a call, time out, rename, remove, or delete the account of only a member standing strictly below them, single and bulk alike.
The same goes for the acts that hand an account over or back: issuing a reset code, clearing a second factor, restoring a removed member (who keeps their roles), and moving someone else between calls.
A permission overwrite on a role or a member, in a channel or a category, follows the ladder too, since it edits that role or acts on that member in one place; `@everyone` is below every role, and a caller's own member overwrite needs no rank.
Managing a bot (creating one, a new token, revoking it, its permissions or prefix) needs every bit the bot holds and a rank above it, because its token acts with all of its roles; a new bot holds the shared Bots role, so its maker must stand above that role.
An invite that grants a role is checked again when it is spent, against its maker as they are then; a maker who could no longer grant the role by hand gives nobody the role.
Another person's invite that grants a role is listed and revocable only for a manager who could grant that role by hand, since its code is that role; and a manager who spends one on their own account gets the role only if they could have granted it to themselves.
A tie is refused, so two members whose highest roles share a position cannot act on each other, and neither can two members with no role.
The ladder runs on top of the permission checks, never instead of them: the caller still needs the bit for the act, and still cannot grant or reach past bits they do not hold.
Every ladder refusal is a 403 carrying `code` `role_hierarchy`; a tie between members keeps the reason `you cannot act on someone of equal rank`.

A member who can manage roles may add or remove their own roles below their highest.
Their highest role is not below itself, so the ladder refuses dropping it, which would be self-demotion past the ladder.

### The Space owner

The owner is the one member the ladder exempts, the way Discord exempts a server owner.
Administrators follow the ladder like everyone else.
Nobody else can moderate the owner, give them a role or take one away.
The last-administrator guard counts only people the owner could pass to, so the last human administrator cannot leave the roles to bots alone.
The owner is not shown anywhere in the interface; profiles and `/me` carry `is_owner` only so a client can leave out what the server would refuse.

The owner is the account that claimed the deployment.
Where that was never recorded (a deployment claimed before migration 0155) or the account is gone, migration 0197 picks the heir a hand-off would: the earliest-joined human administrator, else the earliest-joined human member.
When the owner's account is deleted, or the owner is no longer a member, ownership passes to the earliest-joined remaining administrator, else the earliest-joined member.
There is no way to transfer ownership yet.

#### The owner holds every permission (owner decision, 2026-11-16, later the same day)

The owner holds every permission whatever roles they hold, exactly like Discord's server owner.
The permission evaluator answers every bit for the owner, at the base and in every channel, so no channel or category overwrite can deny the owner anything, the way ADMINISTRATOR already bypasses them.
Every path that works out a principal's permissions agrees: single and batched checks, the channel list, push fan-out, live delivery, search, admin alerts, an invite's role re-check, and the bot and module paths.
The owner also holds every permission an installed module declares, which an administrator holds only by a grant.
A direct message stays outside the role model for the owner too.
Ownership counts only while the stored owner is a live human member: an owner id that points at a bot or a removed account grants nothing, and ownership passes on as above.
The last-administrator guard counts the owner, so the owner may drop or delete the last administrator role; the owner's own account deletion is still refused while nobody else could administer.
The earlier rule that nobody but the owner takes bits from or deletes a role the owner holds is gone, since the owner keeps every permission either way.

#### Hand-offs (review follow-up, 2026-11-16)

The owner is never timed out, like Discord's server owner.
The ladder already refuses timing out the owner, so the only way a timeout could reach one was ownership passing to a member who was timed out.
That member would have been stuck: the owner cannot moderate themselves, and nobody may act on the owner.
So passing ownership on ends any timeout on the heir, and migration 0197 ends any timeout on the owner it picks.
The timeout ends rather than the evaluator skipping it, so the canvas and code-run checks that read a timeout directly agree with the permissions.

A hand-off tells every client: `owner.changed` names the heir, whose own client then re-reads `/me`, its channel permissions and the channel list.
A `profile.changed` for the heir comes with it so every client re-reads their `is_owner`, and a `member.timeout` when a timeout ended.
Both ways a hand-off happens announce it: an account deletion, and a read (`/me`, or any act checked against the ladder) that finds the stored owner gone.
Profile reads never hand ownership on themselves; they report the live owner, if there is one.
Nobody replays those frames to a client that was offline, so every client re-reads `/me`, its channel permissions and the channel list when its socket reconnects, which also covers a role change or a timeout it missed.

A hand-off is also written into the moderation log, under the system actor: a row with a null actor, which only the server writes.
`owner_handoff` records that ownership passed to the heir.
`owner_timeout_ended` is written beside it when the heir's timeout ended, so the log never shows a timeout set and then left hanging.
A null actor otherwise means the actor's account was deleted, so a client tells the system actor apart by these two actions, whose actor is always null.
Migration 0197's one-time pick writes no row.

### Bot roles

A bot's own role and the shared Bots role follow their bots, so nobody grants or revokes either by hand, the owner included.
That refusal is a 409 with `code` `role_follows_bot`.
Deleting a bot's own role by hand stays allowed, under the ladder.

### Bot roles in the Roles list (implementer's choice, 2026-11-17, pending owner review)

This ordering was chosen while building the list, not decided by the owner; it stands until he confirms or changes it.
The Roles list keeps every role at its real position, so a bot's own role is never moved out of its place on the ladder.
Every row keeps the role's own name, the same one its editor shows.
A bot's own role adds the bot's avatar and, under the name, the bot's name; it and the shared Bots role carry a Bot tag, in the same order the ladder has them.
A bot's display name never stands in for the role name, because a bot can call itself "Admin".
A grouped, re-indented list was rejected because dragging inside it would have to lie about rank or need a server rule that keeps bot roles together.
A hand-made role that only bots hold shows a hint in its editor that points to the Bots page; such roles are not deleted.
