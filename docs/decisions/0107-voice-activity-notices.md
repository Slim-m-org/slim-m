<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0107 - Opt-in notices when a call starts, grows or goes live

Status: accepted
Date: 2026-11-04
Builds on [0032](0032-voice-participant-webhooks.md), [0033](0033-notification-schedule.md) and [0049](0049-per-channel-notification-behaviour.md).

## The ask

Friends away from the app should be able to hear that someone opened a call or went live in the evening.
Push covered DM rings, messages and mentions, and nothing about a voice channel.

## What a member chooses

- Per voice channel, off by default: nothing is sent unless the member asked.
- `joins`: off, `first` (the join that starts a call in an empty channel) or `every` (each join).
- `streams`: a separate switch for someone starting a screen share.
- The choice is a row in `voice_notify_prefs` and exists only while something is on.
  `PUT /voice-notifications/channels/{id}` replaces it, off with no streaming clears it, `GET` lists it.
- The controls sit in the channel's Notifications submenu, below the mute and off-hours entries, for voice channels only.

## When a notice is sent

The LiveKit webhook (0032) already knows each real join and each real start of a share.
After it publishes them, one detached task works out the audience and tells it, so a slow notice never turns a webhook into a retry.

An audience member is dropped when any of these is true:

- they are the person who joined or started sharing;
- they are already on the call;
- they blocked that person;
- they cannot see the channel;
- they are on Do not disturb;
- they muted the channel, or muted everything;
- their notification schedule (0033) reads off hours, unless the channel is on their off-hours list.

Nobody is told when the person is hidden (their join must not announce them) or is a bot (a music bot joining would be noise).

## The limit

At most one notice per channel per recipient per ten minutes, shared by joins and streams.
A burst of joins therefore collapses into the first, and a stream started a few minutes after a join is not announced.
The window is in memory: a restart can cost one extra notice, never a lost opt-in.
It is spent only on a recipient the notice can reach, meaning connected now or holding a push device, so an offline member's window is not used up by a call they could not hear about.

## How it arrives

- A `voice.notice` frame to the member's open sockets (`channel_id`, `actor_id`, `activity` of `call_started`, `joined` or `streaming`).
  The server applied every rule above, so a client shows it as it is.
  In front, the client raises a banner with Open and Dismiss.
  A desktop whose window is not in front raises an OS notification instead.
- A push to devices that are not in the foreground, sealed like every other push.
  The relay is sent its existing `message` kind, because it refuses a kind it does not know, and the sealed envelope says `voice`.
  Names ride only to devices that opted into message content (`include_content`), as for a message.

Tapping either opens the channel with its chat showing and the call not joined, the route a notification already uses for a voice channel.
Joining stays one tap away on that screen.

## Known gaps

- iOS rewrites the placeholder from the sealed envelope.
  Android cannot open the envelope in the background, so until the relay learns a `voice` kind its notification reads "New message".
  That relay change belongs to the relay repository.
- Wire contract, migration `0175`, `schema/openapi.yaml`, the iOS notification extension and the client are in one change; the relay is not.
