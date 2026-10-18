# 0035 - When something is a module and when it is a bot

Status: accepted
Date: 2026-09-28

## The ask

The owner, 2026-09-25: "better determination on whether something should be a module or a bot".

Both are generalised primitives, and they are drifting into each other's territory.
A bot wants in-call controls, which is a surface.
A module wants to post messages and remember things, which is an identity and state.
Nothing told a contributor which one to reach for, so the answer was being decided card by card.

This record gives a test that takes about a minute, says which side wins when both apply, and sorts the work already on the board.

## What each one is

A bot is a user-shaped principal that a program someone else deploys authenticates as ([0028](0028-bot-accounts.md)).
It holds a long-lived credential, has roles, is moderated, and lives outside the server process.

A module is sandboxed WebAssembly the host runs ([0021](0021-modules-and-the-dock.md)).
It gets an input and returns an output, has no ambient authority, and reaches the host only through named capabilities an admin approved ([0023](0023-mediated-host-capabilities.md)).

The short version: a bot is somebody, and a module is something the client draws.

## The decision

**Use the checklist below, in order, and stop at the first hit.**
The first two questions decide most cases, because they are about what the sandbox cannot do.

1. Does it need a long-lived secret, or to reach a third-party or LAN service (Jellyfin, a game server, a panel API)? It is a bot. A module has no network and holds no secrets by design.
2. Does it need to run on its own schedule, or react to events with nobody present? It is a bot. A module runs only when a member acts, per viewer.
3. Does it need an identity people can see, mention, moderate, or grant permissions to (it posts as itself, joins a call, is blocked or removed)? It is a bot.
4. Is it an interactive surface rendered inside a message, a scene or the Dock, that is pure, sandboxed, and safe to run from any member's click? It is a module.
5. Is it neither, because it is a property of the client or the server itself? It is core, and a card for the client or server, not a new primitive.

**When both apply, split it: the bot owns state and outside access, the module owns the pixels.**
The bot is the authority (it holds the secret, talks to the outside service, and posts or edits the message).
The module renders what the message carries and sends the viewer's input back as an ordinary action the bot receives over the same API a person uses.
The module never gets the secret and never needs a network.
If the only thing the module would need is to post or remember something on the viewer's behalf, that is a mediated capability under 0023, not a reason to make it a bot.

**Where they overlap, the bot wins on trust and the module wins on rendering.**
Anything that needs a credential or the network is never a module, however small.
Anything that only draws is never a bot, however interactive.

**Decision, 2026-09-28: no personal access tokens.**
Automation goes through bot accounts, which are scoped, audited and revocable.
A person's own credential is never handed to a script.
This closes the personal access token question: a contributor who wants to automate something makes a bot, and the checklist above decides whether a module is also involved.

## The worked cases

| Case | Answer | Why |
| --- | --- | --- |
| Jellyfin watch party | Both | Bot: holds the Jellyfin credential, is the sync authority, posts the invite. Module: the native video surface. They talk through the message and the bot's API actions. |
| Pelican panel | Bot | Needs the panel API key and a LAN or third-party network call (checklist 1). Any status card it posts is plain message content. |
| Minecraft bridge | Bot | Long-lived connection to a game server, runs continuously with nobody present (1, 2), relays as its own identity (3). |
| Starboard | Bot | Reacts to reaction events over time and posts as itself (2, 3). |
| Automod | Bot | Reacts to every message, holds MANAGE_MESSAGES, must be auditable and revocable (2, 3). |
| Music bot | Bot | Joins the voice call as a participant and streams audio (3). A player card is optional and would be a module. |
| Mini-games pack | Module | A board rendered in a message, pure, per viewer, safe from any click (4). Already how connect-four and the others ship. |
| Homelab dashboard | Both | Bot: polls the LAN services and holds the credentials (1, 2). Module: renders the panels in the Dock from what the bot posted. |
| Rich presence | Neither | "Listening to" is core presence, a client and server field. It follows checklist 5, not a new primitive. |
| Code runner | Neither, a brokered service | The server brokers a submission to an operator-run Piston instance and never executes it ([0026](0026-polyglot-code-runner.md)). The odd languages stay modules. |

## What already exists, classified

Checked on 2026-09-28 against `slim-bots/bots` and `slim-addons/modules` (manifests and READMEs).

| Existing | Answer | Checklist reason |
| --- | --- | --- |
| bot: ping | Bot, correct | A reference bot that answers as its own identity (3). |
| bot: greeter | Bot, correct | Reacts to member joins with nobody present (2). |
| bot: modlog | Bot, correct | Mirrors moderation events over time and posts as itself (2, 3). |
| bot: roles | Bot, correct | Grants roles, so it holds MANAGE_ROLES and must be auditable (3). |
| bot: reminders | Bot, correct | Fires on its own schedule (2). |
| bot: jellyfin | Bot, correct | Holds the Jellyfin key, watches a LAN service, joins a call (1, 2, 3). Its `!watch` is the bot half of the watch party. |
| bot: canvas-board | Bot, correct | Draws on the Voice Canvas as an identity and keeps the board between commands (3). |
| bot: casino | Bot, correct with a note | Chip balances are durable per-person state and it posts as itself (3). The game boards themselves are surfaces, see follow-ups. |
| module: connect-four, tic-tac-toe, minesweeper, word-guess, game-of-life | Module, correct | Interactive boards, pure, per viewer, safe from any click (4). |
| module: music-box, spirograph, plot, table | Module, correct | Render a result as a scene or formatted block from the input alone (4). |
| module: dice, hashkit, json-tools, markdown-tools | Module, correct | Pure functions of their input; `message.post` only posts the caller's own result (4, 0023). |
| module: code-exec | Module, correct for now | JavaScript only, in the sandbox, no network (4). Common languages go to the brokered runner in 0026. |

## Follow-ups

None of the existing pieces sits clearly on the wrong side.
Two are worth a card each:

- **casino games:** the two game boards are surfaces that would render better as modules, with the bot keeping only the balance and the payout. Not urgent, and it needs the split wire from "What this does not decide".
- **code-exec:** once the Piston runner from 0026 ships, this module should shrink to the languages the runner lacks, so it does not answer for a language the runner already handles.

## What this changes

- `docs/modules/building-modules.md` and `docs/bots/building-bots.md` each link here in one line.
- A module card that needs a secret or the network is re-scoped as a bot, or split as above.
- A bot card that only renders a surface is re-scoped as a module.
- Rows that sit wrong today are named as follow-ups on the board rather than fixed here. This record is docs only.

## What this does not decide

- Which capabilities a module may eventually hold. That stays with 0023, one review each.
- The wire between a bot and a module for a split case. The first one built (the watch party) settles it, and it gets its own record then.

## Amended 2026-10-18: modules can fetch and run on a timer

The checklist above was written when "a module has no network" and "a module runs only when a member acts" were both true.
Neither is any longer: `net.fetch` and `schedule` shipped on 2026-10-14 ([0023](0023-mediated-host-capabilities.md)), and a module can read the time (`now_ms`).
Questions 1 and 2 therefore sent some secret-free poll-and-post jobs to a bot for a reason that has gone.
This section replaces those two questions and leaves the rest of the record as it was written.

**The revised first two questions, in order.**

1. Does it need a secret, a raw socket (UDP, a game-server query, a database), a connection that stays open, an inbound listener, or a voice call? It is a bot. A module's only way out is one HTTP request to a site named in its manifest and approved by an admin, and it holds nothing a request could not carry.
2. Does it react to events with nobody present (a message, a join, a reaction), keep per-person state or direct messages, post in more than one channel, or need an interval under five minutes? It is a bot. A module's timer is one fixed channel the admin picks, a floor of five minutes, no event input, and a small shared `kv.store`.

A job that clears both is a module when it only polls a fixed set of public sites on an interval and posts what it finds to one channel.
Questions 3 to 5 are unchanged.

**What stays true.**
A module is still not somebody a member can mention or moderate, and a module that needs a long-lived secret is still a bot.
Reaching a LAN service stays possible for a module only through the admin's second approval, which reaches private ranges and never loopback, the server itself or its container network; a job that needs more than one request to a device at home is usually a bot.

**The current poll-and-post bots.**
Checked on 2026-10-18 against `slim-bots/bots`. No bot is retired by this record: a module version is built, left to soak beside the bot, and only then does the bot go.

| Bot | Verdict | Why |
| --- | --- | --- |
| github-releases | Module candidate | Polls one public API on an interval and posts to one channel, no commands. The token it can take is optional and only raises a rate limit. Port first, because it is the cleanest fit. |
| deals | Stay a bot, for now | Needs no key and fetches public pages, but `!pricewatch` keeps per-member watches and pings members by mention, and `!deals setup` picks the channel from chat. Only the free-games half could be a module, and splitting it is not worth the two parts. |
| feeds | Stay a bot | Feeds are chosen from chat, so the hosts are not known when an admin approves the module; a module can only reach hosts its manifest named. |
| uptime-relay | Stay a bot | An inbound webhook listener with a shared secret. A module cannot listen. |
| game-status | Stay a bot | Asks game servers over UDP and raw TCP, which `net.fetch` cannot do. |
| reminders | Stay a bot | Per-member state, per-member time zones, minute-level times and replies to the person who asked. |
| minecraft, pelican, jellyfin, sonarr, radarr, seerr, arrkit | Stay a bot | A credential or a LAN service with a connection that lasts (checklist 1). |

**Reference modules.**
`slim-addons` ships `reminder` (the clock and `kv.store`) and `weather` (`net.fetch`), so an author has a copyable example of each new power.
They are examples of the capabilities, not a claim that those jobs belong in a module rather than a bot.

