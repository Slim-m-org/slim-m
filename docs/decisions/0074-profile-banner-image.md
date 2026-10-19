<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0074 - Profile banner image

Status: accepted
Date: 2026-10-18

## The ask

The owner asked for an image instead of a colour banner on profiles, and chose "like avatars": anyone can upload a static image or a GIF for their own banner, through the same upload path, limits and media handling as avatars.

## Rule

A profile has an optional banner image.
Unset, the card draws the profile colour in the same band, so nothing changes for anyone who never uploads one.
Removing it returns to the colour.

## How it works

- `users.banner_updated_at` (migration 0137) is the only column.
  It is a cache-busting version, as `avatar_updated_at` is; the bytes live in the avatar directory under `banner-<user id>`, a name no UUID has.
- `POST` and `DELETE /me/banner`, `GET /users/{userId}/banner`, mirroring the avatar routes: same 2 MB body cap, same 4096 pixel and 40 MP limits, same rate classes, same `ProfileChanged` event so other clients refetch.
- Unlike an avatar, a GIF is accepted.
  The server stores the file as sent; nothing re-encodes it.
- `banner_updated_at` rides on `UserProfile` and `Me`.
  Account deletion removes the file.
- The client crops a still to 3:1 and shrinks it to fit before upload; a GIF goes up as picked, and is cover-cropped when drawn.
  The band sits above the member card header and in the "How others see you" preview.
  A GIF holds still while the window is unfocused or covered, through `AnimationGate`.

## Not decided here

Per-space banners, banner moderation beyond the existing reporting and removal of an account, and a size beyond the avatar cap.
