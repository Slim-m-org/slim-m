# 0060 - Avatars one step bigger in messages, members and DMs

Status: accepted, 2026-10-07.

## The problem

The owner found profile pictures "pixel-y" next to Discord's (2026-10-05).
Measured first: the stored pictures are 512x512, the client decodes them at three times their drawn size, and the 36px message avatar from the owner's own 1080p screenshot matches a Lanczos downsample of the source pixel for pixel.
So the softness was size, not rendering: a 24 to 36px picture is 24 to 36 physical pixels on a 1080p screen in any app, and Discord draws 40px message avatars and a 48px server rail.

## Decision

Each of the three surfaces the owner pointed at moves up one step of `AppAvatarSize`:

- a message row's author: 36 to 40 (a new `s40` step), and the thread parent card with it, so a reply's parent reads the same as the message;
- a member row: 28 to 32;
- a DM row: 24 to 28.

The continuation gutter of a grouped message follows the message avatar's width, as it already did, so stacked lines stay aligned with the name.
The default `UserAvatar` size and every other surface (pinned, saved, threads, reactions, the rail footer) are unchanged.

## Not done

The rail footer's own picture and the 8px presence dot are separate questions with their own cards.
