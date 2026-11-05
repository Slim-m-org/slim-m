<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0109 - Modules hear six more events, and who reacted

Status: accepted
Date: 2026-11-04
Extends: 0091 (phase 1 contracts), 0100 (add-on API levels)

## The ask

The owner approved giving reactive modules more of what bots already see over the websocket.
Modules had `message.created`, `message.deleted`, `reaction.changed` (a count only), `member.joined`, `member.left` and `voice.session.closed`.

## Decision

Add `message.edited`, `voice.participant.joined`, `voice.participant.left`, `voice.screen_share.changed`, `member.roles.changed` and `poll.voted`, and add `user_id` and `added` to `reaction.changed`.
The wire shapes, ids and fixtures are in `docs/modules/reactive-modules.md` and `docs/modules/event-fixtures/`.

- Level.
  The events are added under `event/1` (a module that ignores unknown fields is unaffected), but a module naming one needs a server that knows it.
  So `ADDON_API` becomes 5, and a manifest subscribing to one of the six with a lower `addon_api` is refused at install.
  `event/1` keeps its version because nothing in it changed meaning.
- Same filters as every event.
  A channel the module's principal cannot view delivers nothing, direct messages deliver nothing, and the principal's own messages and edits are skipped.
- Hidden members.
  The voice events are not sent for a member who chose to appear hidden, the rule the live voice frames already follow (0032).
- Blocked users.
  A reaction by someone the principal blocked is not delivered, as the principal's own live view leaves it out.
  The `count` is still the true total, which only the websocket recomputes per viewer.
- Polls.
  `poll.voted` carries the tally and, on a ranked poll, the winner.
  A poll has no public-voter flag, so no voter identity is ever included.
- Reactions are now per reactor.
  The host remembers each message's reactors (the same 2048-message memory as before) and reports who appeared or went away.
  The first reaction event the host sees for a message after a restart reports every existing reactor as added, as it already reported every emoji; this is covered by the "treat a push as a trigger" advice.
- No migration.

## Not in this repo

`tools/run-module` and the slim-addons docs live in the slim-addons repo.
It needs: the new event names accepted by `--event`, the files in `docs/modules/event-fixtures/` usable as inputs, and `addon_api` 5 in its host simulation.
