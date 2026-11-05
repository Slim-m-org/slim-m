<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0110 - Favorites: GIFs and message media, kept as references

Status: accepted
Date: 2026-11-04

## The ask

A per-user Favorites list for the GIF picker.
It holds GIFs from search and images, GIFs and videos kept from messages.
Space stickers stay out, as `composer_picker_panel.dart` already says.

## Decision

One private, ordered table, `user_favorites` (migration 0176), capped at 200 per account.
It is not a flag on `saved_messages`: a favorite is ordered by its owner and holds GIFs that have no message.

- A GIF entry keeps the provider's two CDN URLs and title, taken from the search cache when it is favorited.
  The search token lives fifteen minutes and a favorite must outlive it.
  The URLs never reach a client; it gets the entry id and reaches the image through `getFavoritePreview` and `selectFavorite`.
- An attachment entry keeps the content hash and the source message id.
  No bytes are copied and no `attachments` row is added, so a favorite never keeps a file alive.
- `selectFavorite` turns an entry into an attachment the composer stages, exactly like `selectGif`.
  For an attachment entry it re-checks that the caller can still view the source message's channel, and answers 409 otherwise.
- `listFavorites` marks an attachment entry `available: false` once its message is deleted or its channel is no longer viewable, and drops the message and channel ids.
  The entry stays so its owner can remove it.
- Adding is idempotent on the client-minted UUIDv7 and on the content.
  A new entry goes first; `reorderFavorites` puts the named ids first and keeps the rest after them.

## Tradeoffs

A stored provider URL can rot, or the provider can be turned off; the entry then fails to send with a 503 and the owner removes it.
Copying the GIF into storage at favorite time would avoid that but spends disk on something the owner may never send again.
