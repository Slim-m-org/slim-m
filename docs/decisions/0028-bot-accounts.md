# 0028 - Bot accounts

Status: accepted, implemented (see the 2026-09-24 amendment for declared permissions, the managed role, ADMINISTRATOR, and the audit trail)
Date: 2026-09-19

## The ask

The owner, 2026-09-19: bots "would be like discord bots", so "spaces need to be able to authenticate bots and handle bots full crud permissions for within spaces", with "a new repo to manage bots or just provide a bot example and somewhere for the documentation on how to develope a bot".

The backlog card that reserved this work (2026-09-06) weighed two shapes and guessed the answer would lean on the module capability model.
That guess is superseded by the ask above.
A module is sandboxed wasm the host runs; it cannot be the thing an external process authenticates *as*.
A Discord-shaped bot is a program someone else deploys, which holds a credential and talks to the API.
So this record designs the second shape the card named: a bot is an account.

## What a bot is

**A bot is a user-shaped principal, not a parallel one.**

This is the whole design, and everything below follows from it.
A bot is a row in `users` with a `is_bot` flag, a UUIDv7 id like any other, no password hash (the column is already nullable), and a membership in the space.

The reason to do it this way is that slim already has one answer to every question a bot raises, and that answer is "the same as for a person":

- Who wrote this message? A `users.id`, which every read path already joins and every client already renders.
- What may it do here? Its roles, and the per-channel overrides on top of them (decision 0011), evaluated by the same `permissions_in_channel` every other action uses.
- What does it see on the socket? Exactly what its permissions allow, because `hub.rs` already authorizes fan-out per subscriber.
- Can a moderator stop it? Remove the member, or revoke its token. Both paths exist.
- What happens to its messages when it is deleted? The same as anyone's (decision 0016, and account deletion's anonymization).

A parallel bot principal would need a second answer to each of those, and second answers are where authorization bugs live.
So the flag is deliberately thin: it changes how a bot *authenticates* and how it is *labelled*, and nothing about how it is *authorized*.

The one place the thin flag was not enough: restoring a removed member. That path was written for a human and reasons "readmission restores the right to sign in, not the old credentials", which is correct for a human and vacuous for a bot, since a bot has no sign-in to retry and its token *is* its only credential. Left alone, that made restoring a removed bot a member-list fiction - it reappeared, and its token stayed permanently dead. The fix keeps the flag thin rather than adding a bot-shaped restore path: restoring a bot un-revokes the one session its live token still points at, scoped by that token's own `revoked_at`, so a token the operator revoked separately stays revoked. See `crates/slimm-server/src/store/removals.rs`.

The second place: listing.
`GET /bots` has no delete, by design.
Hard-deleting a bot's account would anonymize its authorship, which is exactly what "the account stays" above is protecting.
But nothing ever stopped `listBots` from returning a bot either, so a bot that was revoked and then removed from the Space stayed listed forever, with a dead token, after `GET /members` had already dropped it - a short true list about "what has a credential" answered "every bot ever minted" instead.
The fix is a filter, not a delete: `Store::list_bots` leaves out a bot removed from the Space by default, and `include_removed=true` still shows it, since removing it changed nothing about its account or its authorship.
A revoked bot that is still a member is never hidden, because it stays visible everywhere else (the member list, its own messages) and its authorship may be exactly why the row is worth reading.
See `crates/slimm-server/src/store/bots.rs::list_bots` and `GET /bots`'s `include_removed` parameter in `schema/openapi.yaml`.

Freeing a revoked bot's username for reuse is a separate question this record does not answer.
`DELETE /members/{id}/account` already exists for any removed account, bot or human, and already frees the username on deletion - but it also anonymizes authorship, the opposite of what a bot's revocation promises.
Nothing here stops an administrator from pointing it at a bot; whether it should refuse a bot target, or a bot should get some other way to give its name back, is unresolved.

"Full CRUD permissions within spaces", then, is not a new subsystem.
It is giving the bot a role with the bits it needs, out of the eighteen that already exist.
A fresh bot holds whatever `@everyone` holds in that space and nothing more - default-deny, as with any new member.

## Authentication: a long-lived, revocable bot token

A bot does **not** use the access/refresh session pair.

Sessions rotate, and rotation assumes a client that can persist the new pair and, if that goes wrong, a person who can sign in again.
A bot is typically a container with a credential in an environment variable.
It has nowhere to persist a rotated token and nobody at a keyboard to recover, which is exactly the failure this project has already been bitten by from the other end (decision 0024, and the lost-rotation sign-out fixed in #1232).
Rotation would convert every dropped response into a dead bot.

So a bot token is:

- **Long-lived and non-rotating.** One credential, valid until revoked.
- **Hashed at rest**, with the same `hash_secret` every other credential uses. Shown once, at creation, and never retrievable again - the same one-time-reveal shape the admin reset codes already use.
- **Named**, so an operator with several can tell them apart, and **revocable individually**.
- **Provisioned by a member holding `MANAGE_SERVER`**, and every creation and revocation goes on the moderation-audit trail (decision 0015).
- **Presented as `Authorization: Bearer <token>`**, resolved by the same auth extractor, against its own table rather than `access_tokens`.

The mitigation for a long-lived credential is revocation and audit, not a short TTL.
That is a deliberate trade: the token's blast radius is bounded by the bot's *permissions*, which is the control that actually matters, and which a short TTL would not tighten.

A bot receives events over the existing WebSocket, minting a `ws_ticket` with its token exactly as a client mints one with a session.
No new transport.

## What a bot may never do

Three limits are part of the contract rather than the implementation:

- **A bot acts only as itself.** It can never act on another user's behalf, and there is no impersonation parameter anywhere in the surface. This is the sharpest contrast with decision 0023's module capabilities, which deliberately *do* act as the invoking user. A module runs because a person asked it to, inside the host, in that person's context; a bot runs because its operator started it, outside the host, as itself.
- **A bot cannot provision bots.** Token creation requires `MANAGE_SERVER` held by a human member; a bot holding that bit still cannot mint bot tokens, so a compromised bot cannot fork itself into a second credential that survives revoking the first.
- **A bot is not exempt from anything.** Not slow mode, not message retention, not moderation, not per-channel overrides. Where a limit applies to a member it applies to a bot, and where a bot needs a different *budget* that is a rate-limit class, not an exemption.

## Rate limits

Bot traffic is keyed by the **bot's own id**, never by IP.
A bot is a server: its address says nothing about who is calling, and several bots behind one host must not share a bucket.

Bots ride the existing classes with their own budgets, because the shapes differ from a person's: a bot reads and writes steadily rather than in bursts around human attention, and one busy bot must not crowd out the people in a space.
The concrete budgets are sized when the surface is built, against the same reasoning the existing variants document, not guessed here.

## Identity in the interface

A bot appears in the member list and as a message author, with a **BOT badge** beside its name - drawn from the existing design tokens, never an emoji (the interface rule in `docs/design/design-language.md`).
The badge is the one affordance that matters: a reader has to be able to tell that something was written by a program without inspecting anything.

Presence is honest: a bot is online when its socket is connected and offline when it is not.
It does not get a special presence state, and it can be hidden like anyone (decision on presence visibility already allows this).

## Staging

Each stage is shippable and reviewable alone, and nothing before the last one is visible to a bot author:

1. **Identity.** `users.is_bot`, the badge, and the member-list and author-surface reading of it. No auth yet, so nothing can log in as one.
2. **Tokens.** The `bot_tokens` table, provisioning and revocation behind `MANAGE_SERVER`, audit entries, and the auth extractor resolving a bot token to a `SessionContext`.
3. **Admin UI.** Creating, naming, listing and revoking tokens, with the one-time reveal.
4. **Rate-limit classes** sized for bot traffic.
5. **SDK, example and docs**, so somebody outside this repo can actually write one.

Stage 5 is where the owner's "new repo or an example plus docs" question lands.
The reversible answer is taken first: the guide lives in this repo as `docs/bots/building-bots.md`, mirroring `docs/modules/building-modules.md`, and a minimal runnable example beside it.
Promoting the example into a repo of its own is a decision to make once there is something worth promoting, and it is the owner's to make - a public repository under their account is not a thing this record creates on its own.

## What this record does not decide

- Whether a bot may be installed from some registry, or only provisioned by hand. Hand-provisioned, for now, because there is no registry.
- Slash commands owned by a bot. The module system already owns that extension point (decision 0021); whether a bot may register one is a later, additive question.

## Amended 2026-09-24: declared permissions, a managed role, and full permission parity with a human

An audit pass on 2026-09-21 found three things this record left as gaps between "a bot is a role like any other" and what an operator could actually do with that model:

- **No declared permissions.** A bot declared nothing at mint time, so an admin guessed at what role to hand-build. Discord's bot install flow states a permission integer up front and the admin approves it.
- **No managed role.** Discord creates a role named after the bot, holding exactly what was approved, auto-assigned. Here an admin hand-built one by hand, every time.
- **The audit trail claim was false.** This record's own §"Authentication" said "every creation and revocation goes on the moderation-audit trail (decision 0015)." `record_moderation_audit` had exactly five callers, all in member-moderation code; `http/bots.rs` and `store/bots.rs` were not among them.

Two live bots on the owner's deployment were blocked by exactly this gap, not by any permission being too coarse in the sense of missing a finer bit: the **roles** bot could not be handed even a zero-permission `tester` role to grant, because nothing could grant *it* `MANAGE_ROLES` in the first place; the **modlog** bot needed `/reports/history` and the only bit that reached it, `MANAGE_MESSAGES`, also grants deleting anyone's message. The roles bot's case was an honest-grant-flow problem, fixed below by giving bots a real grant path. The modlog bot's case was a genuine finer-grained-permission problem - unlike Discord's "Manage Messages", slim had no read-only sibling for its moderation history - so this record adds one: `Permissions::VIEW_MODERATION_HISTORY`, deliberately deployment-wide rather than per-channel, matching Discord's own "View Audit Log" being a guild permission rather than a channel one. See that bit's own doc comment in `permissions.rs`.

### Declared permissions and the managed role

A bot cannot negotiate anything over the wire before it holds a credential, so there is no handshake to build - the parallel to Discord's OAuth consent screen does not exist here, and this record does not invent one. Instead, `POST /bots` takes a `permissions` bitmask, the same shape `POST /roles` already takes, and the admin sets it informed by whatever the bot's own documentation says it needs. `PATCH /bots/{botId}/permissions` changes it later, a convenience shortcut for editing the same role.

Both routes create or update the bot's **managed role**: a normal row in `roles`, carrying a new `managed_bot_id` column (informational only), auto-assigned to the bot at creation, and evaluated by exactly the same `permissions_in_channel`/`evaluate` path every other role goes through - the central claim this record opened with, still true and still enforced by construction rather than by a second code path.

### The escalation guard is the only permission-side safeguard

`http::roles::grantable` - the check that a role's requested bits are a subset of what the caller already holds - is reused as-is by `http::bots`, unmodified, for both `POST /bots` and `PATCH /bots/{botId}/permissions`. `PATCH /bots/{botId}/permissions` also runs `escalation_guard` against the role's *current* bits before applying the edit, mirroring `http::roles::update`'s identical double check against a human role: a caller must already dominate what a role holds before touching it at all, not only the bits they are about to add.

This is the one safeguard on what a bot may hold, and it is not bot-specific: it is the same rule that already stops one human handing another a role above their own.

### ADMINISTRATOR: a bot may hold it, exactly like a human

An interim draft of this amendment refused ADMINISTRATOR to a bot outright, reasoning that a long-lived, non-rotating token is a worse credential to leak than a human session. The owner overruled that call directly: "why should bots not be able to manage roles, they are effectively just robot users, they should have permissions same as users or roles, and should be able to be admin." Bots are robot users; a bot's power comes entirely from the roles an admin gives it, exactly like a person's, and the platform adds no special case for what a role may contain depending on who holds it.

So: no bot-specific permission cap of any kind. `grantable`, `assign`, `update`, and `administrator_count` treat a bot exactly like a human throughout - none of them inspect `is_bot`. `require_human` still exists, but only for what it always guarded: a bot may not provision or repermission another bot (§"What a bot may never do"), a lifecycle safeguard against a compromised credential forking itself, unrelated to what permissions a bot may hold once it exists. An ADMINISTRATOR bot reaches every route ADMINISTRATOR reaches, human-credential routes (`POST /admin/users/{userId}/reset-code`, `DELETE /members/{userId}/account`) included - see `crates/slimm-server/tests/bot_permissioning/grants.rs`'s parity test.

The safeguards that remain, all principal-neutral: the escalation guard above (nobody grants a role above their own), the audit trail below (who did what), and revocation (a compromised credential is cut off, not merely capped).

### The managed role is a convenience, not a ceiling

An earlier draft also had `http::roles` refuse to edit, delete, assign or unassign a bot's managed role directly, and had `store::revoke_bot` delete it on revoke. Both are gone. The managed role is an ordinary row: an admin can rename it, change its permissions, assign it to a human, or delete it through the plain `/roles` routes with no special case at all. Revoking a bot leaves the role in place - deleting it would have been a silent permission change for any human who came to share it, which is exactly the kind of second answer this record's central claim warns against. Hard-deleting a bot's account (`store::account_deletion`) detaches `managed_bot_id` (sets it to `NULL`) rather than deleting the role, for the same reason; see `tests/account_deletion_coverage.rs`'s entry for that column.

### The audit trail, actually wired

`moderation_audit_log`'s `action` CHECK constraint is widened (migration `0077`, a rebuild per SQLite's own limits, following `0049`'s template, plus the `created_at` index `0068` added since) to add `bot_create`, `bot_revoke` and `bot_permission_grant`. All three are written in the same transaction as the state change they record:

- `store::create_bot` writes `bot_create` alongside the managed role's creation.
- `store::update_bot_permissions` (the store side of `PATCH /bots/{botId}/permissions`) writes `bot_permission_grant`.
- `store::revoke_bot` writes `bot_revoke`.

The acting human is always the recorded actor, never the bot itself, matching every other row in this table. `crates/slimm-server/tests/bot_permissioning/lifecycle.rs` drives all three through HTTP and reads the trail back directly, the same way `tests/moderation_audit.rs` already does for member moderation.

Module lifecycle (install/enable/grant) is a separate, real gap of the same shape - decision 0021 made the identical false claim about its own audit coverage, corrected in the same change that landed this addendum. It is not fixed here: an install/enable/grant has no single subject user the way a bot create/revoke does, and that is a shape question worth its own review rather than a rider on a bot-focused change.

### Where this departs from Discord, and why

Discord installs a bot per-guild through OAuth, with the bot's owner choosing the permission integer in a URL and the installing admin approving it in a consent screen. slim is one deployment per community (`CLAUDE.md`), so there is no cross-server install flow to mirror and no bot-owner-hosted consent screen to redirect through - the bot has no identity in this system until an admin mints its token, so the admin is necessarily the one declaring its permissions too, informed by the bot's own documentation rather than a wire-level request. The managed-role shape (auto-created, auto-assigned) is kept, purely as a convenience: it is good bot-lifecycle hygiene independent of the cross-server install flow it is normally bundled with, and it is never a ceiling here the way Discord's own permission-integer cap effectively becomes one.

### What the roles and modlog bots need, concretely

Neither is granted anything by this change; granting bits on the live deployment is a separate, deliberate admin action, not something this record or its code performs. Once available:

- The **roles** bot needs `MANAGE_ROLES` granted to its own managed role, exactly like any other bit, through `PATCH /bots/{botId}/permissions`. Once held, it can grant a role to a member as long as the role's own bits are a subset of what it holds - a zero-permission `tester` role always qualifies.
- The **modlog** bot needs `VIEW_MODERATION_HISTORY` granted the same way, which reaches `GET /reports/history` without also reaching `MANAGE_MESSAGES`'s message-deletion power.

## Amended 2026-11-11: one shared Bots role, a managed role only when permissions are granted

The owner asked: "can we create a single role for all bots on prod? do they really need their own role for each bot?".
Prod had 27 bots and 20 per-bot managed roles, and 17 of those granted nothing, so the roles list was mostly noise.

What changed:

- **A shared Bots role.** `roles.is_bots_role` (a partial unique index keeps it a singleton, as `is_everyone` does) marks one ordinary role named "Bots" with no permissions, assigned to every bot at creation.
  Admins edit it like any role, and granting it permissions grants them to all bots at once.
  It cannot be deleted (`DELETE /roles/{id}` answers 409), so it is never missing.
  It is created by migration `0184` when the deployment already has bots, and otherwise by the first bot created.
  The role DTO carries `is_bots_role`, additively.
- **The managed role is optional.** `POST /bots` with permissions 0 creates no managed role, and `Bot.role_id` is null.
  `PATCH /bots/{botId}/permissions` creates the managed role when the bot has none and the new bits are non-zero, and deletes it, with its assignment and overwrites, when set to 0.
  The escalation guard and the audit trail are unchanged, and a bot without a managed role is guarded as holding 0 bits.
- **A bot is identified by its record, not by its role.** A bot is a live `users.is_bot` row with a `bot_tokens` row; a module principal has none and still is not a bot (`Store::is_bot_account`).
- **Migration.** `0184` assigns the Bots role to every existing bot with a token record, and deletes managed roles whose permissions are 0.
  Managed roles that grant something are kept.

The earlier "managed role" sections above still hold for a bot that has one.
