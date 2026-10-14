# 0065 - Temporary voice rooms, as a voice channel setting

Status: accepted, 2026-10-13.

## The problem

The owner picked "temporary voice rooms" from the 2026-10-13 option list, where the gaming and study testers both chose it.
The study tester argued it belongs in the channel settings rather than in a bot, and the card asks for a room the joiner owns, which they can rename, lock and cap, removed when it empties.

## The model

A voice channel can be a lobby: `creates_rooms` on the channel, set by anyone with MANAGE_CHANNELS.
Opening a lobby does not join it.
The client asks the server for a room (`POST /channels/{id}/voice/room`), and the server creates a voice channel named after the person, right below the lobby in the same category, with a copy of the lobby's overwrites so exactly the same people can see it.
Asking again while that room exists returns it instead of making a second one, which is what makes the request safe to retry.

A room is an ordinary voice channel with an owner (`room_owner_id`), so everything that already works on a channel (calls, the canvas, chat, permissions, the live channel list) works on a room with no special case.

The owner, or anyone with MANAGE_CHANNELS, changes three things through `PATCH /channels/{id}/room`:

- the name;
- locked: nobody new can join, checked when a voice token is minted; people already in the call stay;
- a user limit, which is also a plain setting on any voice channel (`user_limit`, 0 for none), checked the same way.

The owner and anyone with MANAGE_CHANNELS are never turned away by a lock or a limit.

## Removal

A room is deleted once nobody is in its call.
The voice webhook's `participant_left` triggers a check against LiveKit's own participant list, and a sweep every minute catches anything a missed webhook leaves behind, skipping rooms younger than a minute so one that was just created is not removed before its owner arrives.
Deleting goes through the normal channel delete, so clients drop it the same way.

## Why not owner permissions

Giving the owner MANAGE_CHANNELS and MANAGE_ROLES overwrites on their room would reuse the existing settings screens, but the overwrite editor refuses to let someone grant or lift what they do not hold deployment-wide, so a member could not have locked their own room with it, and it would hand a member the full permission editor for a channel.
A small owner route with three fields keeps a room's owner exactly as powerful as the card asks and no more.
