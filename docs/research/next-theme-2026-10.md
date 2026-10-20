# Next theme: portability (bring history in, take it out)

Date: 2026-10-19.
Question from the owner: choose another theme to go for, after researching.

## Result

Chosen theme: portability.
Moving a Discord community in, and taking a community or a member's own data out.
Today slim-m has neither direction: no importer, no space export, no member data export.
Verified on `feat/batch15` at 32f18a000: no export or import route in `schema/openapi.yaml`, none in `crates/slimm-server/src/http/`.
The only backup path is the operator script `scripts/backup.py` (raw database and media copy).

## Evidence

- Discord rolled out age verification (face scan or ID) in 2026 after a September 2025 breach that exposed about 70,000 ID images ([Maileroo](https://maileroo.com/blog/discord-is-changing-everything-in-2026-heres-what-you-need-to-know-plus-the-best-alternatives/), [Privacy Guides thread](https://discuss.privacyguides.net/t/discord-will-soon-require-face-scans-or-id-for-all-users-or-restrict-access/35323.md)).
- The surge to Stoat was large enough that its status page admitted performance problems ([TechRadar](https://www.techradar.com/computing/social-media/so-many-discord-users-are-flocking-to-this-alternative-platform-its-making-stoat-crash)).
- I found no sign that Stoat imports Discord history ([search](https://vale.rocks/posts/stoat-history) covers the rename only).
- Haven (AGPL, Docker) lists Discord history import as a feature, so a competitor already treats it as a selling point ([Cloudzy listing](https://cloudzy.com/es/marketplace/haven/)).
- Guilded closed on 2025-12-19 and made content inaccessible after an export window ([AlternativeTo](https://alternativeto.net/news/2025/11/guilded-to-shut-down-on-december-19-2025-as-focus-shifts-to-roblox-communities/)).
- Lesson from Guilded: a community cannot trust a platform it cannot leave with its data.
- Friend groups stay on Discord out of network effect, not features ([TeamSpeak forum](https://community.teamspeak.com/t/why-would-most-people-use-teamspeak-5-over-discord/1864), [Lemmy](https://lemmy.fraxoweb.com/post/14850/17723)).
- Discord search misses partial words and loses reply context, and its content is not indexed anywhere ([Discord support](https://support.discord.com/hc/ko/community/posts/22857585017623-Discord-Search), [Lemmy](https://lemmy.klein.ruhr/post/200522/833797)).
- Matrix self-hosters report hard setup, silent federation failures, unreliable push, and a heavy Synapse ([Lemmy thread](https://lemmy.sudovanilla.org/post/3380/32692)).
- Stoat self-host guide estimates 45 to 75 minutes of setup; Fluxer self-host is about 25 containers ([RamNode](https://ramnode.com/guides/revolt), [search listing](https://railway.com/deploy/fluxer-open-source-discord-alternative-text-chat--fluxer-chat.md)).
- Caveat: nearly all of this is anecdotal forum and press material, not survey data.
- Caveat: I could not find reliable sources on Discord outage or ad complaints for small servers.
- Internal: the board already holds a parked card, "A community moving off Discord has to abandon its history" (1856070256963880465), whose own text calls switching cost the competitor's main defence.
- Internal: the Discord account link shipped (OAuth identify, linked_accounts); the history slices of that card did not.
- Internal: `docs/BACKLOG.md` line 96 already lists "Cross-instance import and portability" as a wanted item.

## Candidates

| Theme | For | Board overlap | Size | Main risk |
| --- | --- | --- | --- | --- |
| A. Portability (chosen) | Groups leaving Discord; owners who want an exit | Link shipped; import parked; no export | L | Imported-author model touches seq, FTS, account deletion |
| B. Community memory | Long-lived groups | Cross-channel search, pins, saved, threads, starboard, digest bot all shipped; OCR card exists | M | Mostly built already; remaining gains are incremental |
| C. Zero-ops self-hosting | New operators | Backup scripts, storage view, first-run setup card, metrics exist | M | Scattered across cards that already exist; a polish pass, not a direction |
| D. Small-group coordination | Game nights | Events/RSVP, scheduler, focus timer cards in backlog; polls shipped | M | Better as modules or bots per decision 0035 |
| E. Mobile call reliability | Phone users | Android foreground service, battery policy cards exist | M | Needs real-device owner testing, which is unresolved |

## Choice and why

A fits the strategy: one deployment is one community, self-hosted, and the product's pitch is an alternative people already know.
It is the only candidate that lowers the main switching cost, which the evidence ranks above feature gaps.
The export half answers the Guilded lesson and fits the privacy stance without any content scanning.
B and C are largely built, so a theme would mostly re-label existing cards.
D is better served by the module and bot system.
E is blocked on hardware only the owner has.

## How it fits the constraints

- Transport encryption only: import and export operate on plaintext messages the server already stores.
- No content scanning: the importer must not scan or classify; it copies.
- Privacy: a member data export covers only that member's own data; a space export is admin only and permission scoped.
- Imported authors who never sign up need a placeholder principal; this must be decided against account deletion tombstones before building.
- Order: imported messages need minted seq and UUIDv7 ids for past timestamps; one decision record first.
- Discord limits: no OAuth scope returns DM history; a user data package holds only that user's own messages, so DM import is one-sided.
- Discord terms: reading guild history needs a bot the guild admin adds; a user token must not be used.

## Risks

- Largest: the import path touches nearly every table; ship channels and messages first.
- Imported content could be large; it must respect retention and the 512 MiB server limit.
- Plain-text author mapping can mislead; imported rows must be visibly badged.
- Needs owner answers on the points listed in the epic.
