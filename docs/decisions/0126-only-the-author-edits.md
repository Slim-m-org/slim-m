<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0126 - Only a message's author can edit it

Status: accepted, 2026-11-17.

## The ask

The owner, 2026-11-17: "I dont think admins should be able to edit other peoples messages, I think we should remove that functionality".

Until now `MANAGE_MESSAGES` (and so `ADMINISTRATOR`) let someone edit any message in a channel they moderate.
No decision record granted it; `docs/PRODUCT.md` and the permissions doc described it.
The client never offered Edit on someone else's message, so only the API could do it.

## Decision

- `PATCH` on a message is author-only.
  Anyone else, moderators and administrators included, gets 403 with `code: not_author`, and the client reads it as "Only its author can edit it."
- The author still needs `SEND_MESSAGES` in the channel to edit.
- Bots and webhooks edit their own messages as before; nothing in the first-party bots or modules edits another account's message.
- Moderation keeps delete, which `MANAGE_MESSAGES` still grants and which is audited.

## Why

Editing someone else's words puts text under their name that they did not write.
Delete removes a message without misattributing anything, so moderation loses nothing it needs.

## Compatibility

The change narrows a permission, which is the point.
No shipped client used the moderator edit path, so nothing a person can see stops working.
