# 0116 - an old search hit opens a read-only window around it

Status: accepted, 2026-11-13.
Builds on the jump-to-message path (`MessageJumpController`); it changes nothing for hits it can already reach.

## Decision

The owner, 2026-11-13: build "open a search hit older than the transcript window" with a context window.

- Tapping any hit, however old, shows that message in context, scrolled to and highlighted.
  A pinned bar over the transcript says "Viewing older messages" and has a "Jump to present" button, so getting back is one tap.
- The window is read-only and lives in memory.
  It is never written to the local store, so the store keeps its contiguous history, its cursors and its read marker, and nothing is marked read while it is up.
- `MessageJumpController` still tries first: a hit the store holds, or that paging can reach within `channelWindowCeiling`, opens the live transcript exactly as before.
  The window is only the fallback for a hit past that ceiling or not in the store.
- A message the server no longer has keeps the "Could not find that message" refusal.

## How it works

- **Server.** `GET /channels/{id}/messages` takes an additive `around=<seq>`.
  It returns the page centred on that seq, newest first, in the same shape and with the same view permission and size clamp as `before`.
  Combining `around` with `before` is a 400.
- **Client.** The jump fetches the hit for its seq, then the page around it, and holds the rows in `messageContextWindowProvider`.
  The transcript pane shows them in place of the live window, reusing the same message rows and the jump highlight.
  Leaving the channel, or a jump the live window can satisfy, closes it.
- The window has no paging of its own: it is one page of up to 100 messages.
