# 0069 - Bot prefix assignment

Status: accepted; built
Date: 2026-10-18

## The ask

The owner: "plan out a prefix assignment during bot being added to a space so we make sure they dont overlap, only allow multiple bots to use the same prefix if there is no overlap".
Two shipped bots both answered `!watch`, and the composer listed it twice.

## What was wrong

Decision 0031 let every bot register its own prefix and commands, and deliberately left two bots on one prefix and name visible rather than resolved.
Nothing compared bots, so the clash only showed up as one message running one command while the other bot sent a usage error.
The framework hardcoded `!`, with an environment override per bot.

## Decision

The server assigns the prefix, and refuses a clash when a bot registers.

- Creating a bot takes an optional `prefix`. When it is absent the server assigns `!`, because the released library hardcodes it and shared prefixes are fine while commands differ. `GET /bots/suggested-prefix` returns the first free one for the create form, which sends it explicitly. A prefix is free when no live bot holds it; a revoked, removed or deleted bot's prefix is free again.
- The prefix is stored on the bot (`users.bot_prefix`) and returned on `Bot.prefix` and, for the bot itself, on `Me.bot_prefix`. A bot that predates this adopts the prefix it already registered, through a backfill in the migration.
- Two bots may share a prefix. The check that matters is per command: registering `(prefix, name)` while another live bot has registered the same pair, compared case-insensitively, is left out of the later registration, which still succeeds and lists the left-out names in the `x-slimm-dropped-commands` response header. A bot always keeps a name it already held, so a clash that predates this rule never blocks either bot (the released library retries a 409 forever). Two bots on `!` with disjoint command names both register. Registration is a single write transaction, so two bots racing for one name cannot both win.
- A registration under a prefix other than the assigned one is refused with 409. A bot with no assigned prefix adopts the one it registers. The first registration under a name wins; a later one has to rename.
- The framework reads `Me.bot_prefix` on connect and uses it in place of the constructor default or `SLIMM_PREFIX`. When those disagree it logs which one it used. A registration with left-out names logs them at warning level from the header.

## Composer hints

`GET /channels/{channelId}/bot-commands` answers each `(prefix, name)` once. Rows registered before refusal existed can still clash; the older registration is listed and the later one is left out, matching which registration would have won. Each row keeps showing its bot's real prefix, and the bot name stays on the row.

## Not decided here

- Whether a prefix may be changed after assignment. For now it cannot be changed by the bot, and an admin has no route to change it either; revoke and recreate.
- Matching on the first word of the typed text. The server only knows registered names, so a bot that accepts commands it never registered is outside this check.
