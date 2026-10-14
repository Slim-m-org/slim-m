---
category: Chat
---

# MessageRow

One chat message as the transcript draws it: author avatar, name and time, then reply quote, body, attachment, reactions and send state. Rows have no card; the hover fill and a failed row's red edge are the only chrome.

## Wide vs compact

Decided by the width of the nearest `SlimRoot`, never by platform (`message_row.dart` reads `LayoutClass`).

- 600px and wider: 20px side gutter. `hovered` fills the row with the raised surface and shows the action toolbar (react, reply, thread, edit, more) at the top right. The header and a grouped row's first line reserve 166px on the right so text never runs under the toolbar.
- Below 600px: 10px gutter, no toolbar, no clearance. The same actions live in the long-press menu, which is a separate mock.

Type, avatar size and radii never change with width.

## Usage

```jsx
<SlimRoot style={{ width: 760 }}>
  <MessageRow author="Mara Lindqvist" time="9:41a" body="Pushed the new call dock." reactions={[{ emoji: '\u{1F44D}', count: 3, active: true }]} />
  <MessageRow author="Mara Lindqvist" time="9:42a" grouped body="Spacing is 8px on the ring." />
  <MessageRow author="release-bot" time="10:02a" bot body="Released client 0.104.0." />
</SlimRoot>
```

## Rules

- Group a message under the previous one (`grouped`) when the same author sent it within the density window: 2 minutes at compact density, 1 minute otherwise. A grouped row has no avatar or header; its time shows in the gutter on hover, and always while it is sending or failed.
- `density` is vertical rhythm only: group gap 4, 8 or 12 and grouped gap 1, 2 or 4. The compact density also uses a 28px avatar; the others use 40px.
- `bot` gives a square avatar and a `Bot` tag badge. A bot's own edits are not marked, so leave `edited` off for bots.
- `edited` appends a quiet "edited" after the last line of the body.
- `status="pending"` dims the body to secondary ink and shows a clock and "sending" in the time slot. `failed` adds a 2px danger edge, "not sent", the reason line and Retry (danger) and Discard buttons. Reactions are hidden on an unsent row, and so is the toolbar.
- `@mentions` use `<Mention>`, an accent-soft pill. The app has no whole-row highlight for a mention of you.
- `attachment` takes a node; `true` draws the 420 by 168 striped stand-in. Reactions use `Chip`, with the emoji written as a `\u{...}` escape.
- The column never grows past 760px.
