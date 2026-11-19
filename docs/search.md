# Message search

One search serves the whole app: the command palette.
`Ctrl K` opens it over everything; a conversation's search button opens it with that conversation already filled in as an `in:` filter.
This page is the query grammar and where each part lives.

## Grammar

A query is free text plus any number of `key:value` filters, in any order.
Free text matches whole words and word prefixes (`win` finds `Windows`); a word of one letter matches whole.
`"an exact phrase"` in quotes matches those words together, and FTS5 syntax (`AND`, `OR`, `NOT`, `NEAR(...)`, `*`) keeps its meaning.
A value with spaces is quoted too: `in:"team chat"`.

| Filter | Value | Matches |
|--------|-------|---------|
| `from:` | `@username` or `username` | messages that person wrote |
| `mentions:` | `@username` or `username` | messages with a direct `@username` that pinged them; an `@everyone`, `@here` or role mention does not count |
| `in:` | `#channel`, or a conversation picked from the list | that channel, DM, group or thread |
| `has:` | `image`, `video`, `file`, `link`, `voice`, `poll`, `embed`, `attachment` | messages carrying that; `file` is any attachment that is not an image, video or voice message, `attachment` is any at all, `embed` is a bot or webhook embed |
| `pinned:` | `true` or `false` (`yes`, `no`) | pinned, or not pinned |
| `before:` | `YYYY-MM-DD` | sent before that day, the day itself excluded |
| `after:` | `YYYY-MM-DD` | sent on or after that day |
| `during:` | `YYYY-MM-DD`, `YYYY-MM` or `YYYY` | sent on that day, in that month or in that year |
| `between:` | `YYYY-MM-DD..YYYY-MM-DD` | sent between the two days, both included |

`type:` is read as `has:`, so `type:image` works too; there is no separate type filter, because `has:` already says what a message carries.
`has:` filters add up: `has:image has:link` wants both.
For `from:`, `mentions:`, `in:` and `pinned:` the last one given wins.
The date filters narrow each other to the window they all allow, so `after:` with `before:` is a range.
Days are UTC calendar days, the same on every device.
A filter whose value does not fit its key (`has:sticker`, `before:2026-02-30`) stays plain text.

A name that matches nobody, or a channel the searcher cannot see, gives no results rather than an error, so search can never tell anyone a hidden channel or an account exists.

## In the palette

Typing a key offers its values: people for `from:` and `mentions:`, channels for `in:`, the kinds for `has:`, and quick dates (today, yesterday, this month, the last 7 days) for the date keys.
Picking one, or finishing a filter with a space, turns it into a chip under the field; a chip is its own remove button.
With any chip the palette searches messages only, 25 at a time with a row that loads more.
While it does, the field offers the keys themselves as the word being typed could become one.

Keys: arrows move, Enter picks, Tab completes a suggestion (and otherwise moves between sections), Backspace in an empty field removes the last chip, Esc closes.
Below `kCompactWidth` the palette is the pull-down panel with Cancel in place of Esc, chips under the field; see `docs/design/desktop-vs-mobile.md`.
A hit opens through the same jump every other result uses: the conversation pages to the message and flashes it, and says so above the transcript while it is finding it or if it cannot.

## Where it lives

- Grammar: `client/packages/app/lib/src/features/messages/providers/message_search_query.dart`, folded into route parameters by `message_search_request.dart`, run by `message_search.dart`.
- Palette: `features/palette/` - `palette_query.dart` (the field and its chips), `palette_filter_suggestions.dart`, `palette_filter_chips.dart`, `palette_message_search.dart` (paging).
- Server: `crates/slimm-server/src/http/search.rs` and `store/messages/message_search_filters.rs`; `docs/internals.md` "Message search" has the reasoning.
- Wire: `GET /search/messages` and `GET /channels/{channelId}/messages/search` in `schema/openapi.yaml`; an `in:` picked from a list uses the second, by id.
