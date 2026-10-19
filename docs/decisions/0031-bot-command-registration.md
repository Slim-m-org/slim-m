# 0031 - Bot command registration

Status: accepted; built (the server surface, the composer and the prefix/profile/mention-card follow-up)
Date: 2026-09-24

## The ask

The owner, earlier: "are bots able to publish their list of commands to the server to allow me to do ! or whatever the prefix is and see the possible commands? if not perhaps make it so."
Later, directly: "do command registration now too."
The broader brief: "keep iterating until the bots behaviors, life cycles, safeguards, and proper permissioning is correct, reference discord if needed."

A follow-up scope addition, landed as its own PR after the core of this record: a bot also registers its own prefix, its profile popover shows its prefix and commands, and @mentioning a bot shows a locally-rendered, mentioner-only help card built from the same registration data.

Decision 0028 (bot accounts) named this exact question and deliberately left it open: "Slash commands owned by a bot. The module system already owns that extension point (decision 0021); whether a bot may register one is a later, additive question." This record answers it.

## Advertisement, not interactions

Discord's real model is interactions: invoking a command sends a structured, typed request carrying the invoker's identity to the bot over a socket, and the bot answers it. The alternative - advertisement - is much smaller: a bot registers a list of `{name, description}` pairs; the composer offers them; picking one inserts plain text; the message posts exactly as if the person had typed it by hand, and the bot's own process recognizes and answers it exactly as it does today.

**This record chooses advertisement**, for three reasons that all point the same way:

1. **It is additive to every bot that exists.** A bot that does nothing today keeps doing nothing; a bot that already parses `!ping` keeps working unchanged whether or not it ever calls the new registration route. Interactions would require every bot author to add a second code path (a websocket frame handler that answers an interaction) before registration bought them anything at all.
2. **The server enforces nothing either way**, so the honest framing is a discovery aid, not an authorization boundary. Advertisement is honest about that from the wire shape up: it has no field that could be mistaken for enforcement. Interactions look more like a permission check (they could carry the invoker's identity) while actually providing none server-side, since nothing stops a person from typing the raw command text and bypassing the interaction entirely - a bot must still verify the sender either way.
3. **It does not reopen the identity-stripping question.** `http::ws::frames` deliberately withholds reactor identity and poll-voter identity from the wire (see that module's own doc versus `hub::Event`), so a bot cannot see who reacted or voted - a deliberate privacy line for actions that read as low-commitment and often anonymous-feeling even in public. An interaction model would hand a bot the invoker's identity on every command call, for free, as a platform primitive - a strictly larger disclosure than reactions or votes ever get, on the strength of nothing more than "the composer offered it as a button." That is inconsistent with the platform's existing posture unless made a deliberate, separate decision. Advertisement never raises the question: the bot learns who sent a command exactly how it learns who sent any other message, through the same message-author field every other read path already carries, gated by the same permissions.

Advertisement is designed so interactions can be added later without a breaking change: `BotCommand` already has a stable `name`, and a future interaction-capable bot could declare that a specific command wants a structured invocation without touching how any other bot's plain-text command is offered or sent. Nothing in this record forecloses that; it only declines to build it now, on the evidence above.

## Prefix, and the `/` collision question

The original framing was "does a bot command join the composer's `/` menu, or get its own trigger." The scope addition sharpened this: bots do not all share one prefix (`!`, `?`, `$`, a word), so a fixed answer to "what character does a bot register under" was never going to be right.

**The resolved design:** a bot registers its own `prefix` alongside its commands, in the same bulk overwrite. The composer keeps exactly one typed discovery trigger - `/`, already wired for modules and built-ins, so no new trigger-detection surface, no new `e2e_labels.py` risk, and no divergence from `autocomplete_query.dart`'s existing "`/` only counts at offset zero" rule. Typing `/` lists bot commands alongside module commands and built-ins, each bot command's row labelled with **its own registered prefix and name** (`!ping`, not `/ping`), and picking it inserts exactly that text - the bot's own prefix followed by its own keyword. Discovery is unified; invocation is not rewritten to match it.

This resolves the collision risk directly: a bot's prefix is validated to reject `/`, `@` and `:` (the composer's own reserved triggers - see Limits below), so a bot's advertised text can never collide with a module's `/name` slash command, which is the one collision that would silently misfire (module commands are intercepted and run before posting via `matchSlashCommand`; a bot command is never intercepted, it always just sends). Two different bots sharing the same prefix and the same command name can still produce identical rows (e.g. two bots both answering `!ping`); this is left visible rather than resolved, the same as it is in Discord's own multi-bot-one-prefix world - the composer shows the bot's own name and description on the row (`bot_display_name`, `description`) so the ambiguity is legible instead of hidden, and picking either row sends the same message both bots' processes see, exactly the behavior a person would get typing it by hand with both bots present.

**Existing module-command collisions are not made worse.** Nothing about this record changes `reachable_extension_points`'s newest-first resolution for two modules sharing a slash-command name; bot commands live in a disjoint table, are never matched by `matchSlashCommand`, and never influence which module command an ambiguous `/name` send resolves to.

## Permission gating

A registered command may declare a single `permission` bit (the same `Permissions` bitmask `GET /channels/{channelId}/permissions` already returns). The channel-scoped discovery route (`GET /channels/{channelId}/bot-commands`) hides a command from a caller who lacks that bit in the channel being composed in, exactly as `GET /modules/slash-commands` already hides a module command from a caller without its permission.

**This is a hint, not enforcement, and both `schema/openapi.yaml` and `docs/bots/building-bots.md` say so in the caller-facing text.** The server does not gate *sending* the plain message the command becomes - anyone who can post in the channel can type the raw text by hand regardless of what the composer chose to show them. A bot author who wants an actual permission check must ask the API for the sender's permissions (`GET /channels/{channelId}/permissions`, evaluated for the message's own author) before acting, the same way it always has. The gate exists only to keep a moderator-only command out of a composer's suggestion list for someone who cannot use it, matching Discord's own `default_member_permissions` framing precisely: it hides, it does not authorize.

## Visibility

`GET /channels/{channelId}/bot-commands` leaves out a bot's entire registration unless the bot itself currently holds `VIEW_CHANNEL` in that channel - checked with the same `Store::permissions_in_channel` evaluator every other visibility check in this codebase uses, applied to the bot's own principal rather than the caller's. A bot with no access to a channel does not get to advertise itself there any more than a person would be suggested as someone to `@mention` in a channel they cannot read.

The route also masks its own answer to an empty list whenever the *caller* lacks `VIEW_CHANNEL`, mirroring `getChannelPermissions`'s existing "refuse identically" rule: without this, an ungated bot command would otherwise still appear for someone with no visibility into the channel at all, turning the list into a channel-existence oracle.

## Lifecycle

Registration is a full bulk overwrite, all-or-nothing, in one transaction (`Store::set_bot_commands`): a bot resends its complete prefix-and-command set on every connect, and a command it drops from its own source actually disappears, rather than surviving as a stale advertisement nobody will answer. A set that fails validation leaves the previous registration completely untouched.

A revoked bot's commands vanish from discovery immediately - there is no separate cleanup step, because `visible_bot_commands` only ever joins against a live (non-revoked) `bot_tokens` row. A bot removed from the Space vanishes the same way, via the same `space_removals` anti-join `Store::list_bots` already uses. Both are covered by regression tests that fail when either join condition is removed (see Testing below).

**A bot's commands remain listed while it is offline.** Presence (a live websocket) and credential validity (a live, unrevoked token) are different things: an offline bot can reconnect at any moment, and hiding its commands while it happens to be down would be equivalent to hiding the ability to `@mention` or DM someone merely because they are not currently online - this platform does not do that anywhere else, and a bot command's send path is exactly as tolerant of a slow answer as any other message is.

`GET /bots/{botId}/commands` (a profile's own read) is unfiltered by channel or by any viewer's permissions: it answers "what does this bot support," which is stable historical information about the account, similar in spirit to how a removed bot's authorship survives (decision 0028) - a profile is allowed to keep describing an account even where the discovery list would now hide it.

## Limits

Stated in prose in `schema/openapi.yaml`'s `setBotCommands` description, since the additive-schema gate rejects new parameter constraints there:

- At most 50 commands per bot.
- A prefix is 1 to 16 characters, contains no whitespace, and must not be `/`, `@` or `:` - the composer's own reserved triggers.
- A command name is 1 to 32 characters of letters, digits, `-` and `_` (no leading punctuation - the prefix supplies that), and must be unique within one bot's set, case-insensitively.
- A description is 1 to 100 characters.
- An optional `usage` hint is at most 80 characters.
- An optional `permission` is exactly one bit of `Permissions`.

A registration that violates any of these is refused outright (400), not truncated or partially applied.

## The registration API, exactly

For a bot library building against this (e.g. a discord.py-shaped framework calling this automatically from `@bot.command`):

```
PUT /bots/commands
Authorization: Bearer <the bot's own token>
Content-Type: application/json

{
  "prefix": "!",
  "commands": [
    { "name": "ping", "description": "check if I'm alive" },
    { "name": "roll", "description": "roll dice", "usage": "<sides>", "permission": null }
  ]
}
```

- `prefix` (string, required): what this bot answers to. Caps above.
- `commands` (array, optional, defaults to `[]`): the bot's **entire** command set - this call replaces whatever was registered before, in full. Each entry:
  - `name` (string, required)
  - `description` (string, required)
  - `usage` (string, optional)
  - `permission` (integer, optional): a single `Permissions` bit (the same encoding `GET /channels/{channelId}/permissions` returns), or omit/null for open to anyone who can see the bot.
- Response: `204 No Content` on success, `400` naming the violated cap, `403` if the caller is not a bot.
- **Call this once per connect, with the bot's complete current set.** There is no add/remove-one-command call. A library wrapping this should collect every `@bot.command`-registered command at startup (or whenever the set changes) and re-PUT the whole list.
- Reading it back: `GET /bots/{botId}/commands` returns `{ "prefix": string | null, "commands": [{name, description, usage}] }` (no `permission` echoed back, and no auth requirement beyond being signed in - any member can read any bot's registration, the same visibility a profile has).

## The prefix/profile/mention-card follow-up

Landed as its own PR, after the core registration surface, per the coordinating agent's instruction not to hold up the base PRs:

- **Profile.** Clicking a bot's name already opens `member_profile_popover.dart`/`member_profile.dart`. For a bot, this now reads `GET /bots/{botId}/commands` and shows the prefix and each command's name/description, capped and scrollable so a bot with many commands cannot break the popover's own measured-collision layout (`#1302`).
- **Mention help card.** `@mentioning` a bot shows a card visible only to the person composing the message, naming the bot, its prefix, and its commands - built entirely client-side from the same registration data the composer already fetched for discovery, so it needs no new server primitive, works even when the bot is offline, and never leaves the device: no fan-out, no history row, nothing to sync or search. It appears once per distinct bot mentioned while composing (not once per keystroke, not once per repeated mention of the same bot), and a bot with nothing registered shows no card at all rather than an empty one.
- **Deliberately not built here: a server-side ephemeral message primitive.** A bot replying privately to one person - "you lack permission," "your balance is 500" - is a real, valuable feature, but it is security-sensitive in a way that deserves its own design: it must never reach another user's socket, persist into another user's history, or surface in search or sync. That is carded separately rather than folded into a client-only help card that happens to look similar.

## Addendum: command options with fixed choices

A command may declare up to 5 positional `options`, each a name, a `required` flag and up to 25 `choices` (migration 0135, a JSON column on `bot_commands`).
The server validates the shape at registration only: a bad option refuses the whole registration with a 400.
An invocation is still the plain message the bot receives, so a value outside the list is delivered and the bot enforces it; slimbots does that for a command declared with `choices=`.
The composer shows a keyboard-navigable pick list, filtered as you type, once the keyword and a space are typed and the option under the caret has choices.
An option without choices is free form and offers nothing.

## What this record does not decide

- Whether advertisement ever grows into a real interaction model. The `name`-keyed shape is left stable enough to support that later, but nothing here designs it.
- The server-side ephemeral message primitive named above (built later, see decision 0037).
- Any change to the pre-existing module-command newest-first collision resolution; this record only guarantees it does not add a second version of that problem.
