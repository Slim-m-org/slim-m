---
category: Shell
---

# ChannelHeader

The bar above a conversation: channel glyph, name, topic and the pane actions (pins, threads, search, members).
Use it as the `header` slot of `AppShell`, one per open channel.

## Width

- 600px and up: a 52px bar with a hairline under it. Name and topic sit on one line, the name capped at 60% of the title block, a 1px rule between them. Actions on the right at pointer size: pins, threads, search, members.
- Under 600: a 48px app bar. A back button leads, the title stacks name over topic, actions are touch size. The member button opens the member drawer; there is no toggle state. Voice channels drop pins and search and show the text chat button instead.

## Kinds

`text` shows a hash, `voice` a speaker, `dm` the peer's avatar and `notes` the notebook glyph of the self-DM. `restricted` swaps the hash or speaker for a lock. A DM has no member button and gets a call button.

## Usage

```jsx
<ChannelHeader
  name="design-review"
  topic="Mocks, specs and the odd bikeshed"
  searchOpen
  membersOpen
/>
```

- `searchOpen`, `membersOpen` and `textChatOpen` light the matching button with the accent state; leave them off for a resting bar.
- `textChatToggle` shows the docked text chat toggle on a voice channel (wide layouts only).
- The topic is one line and truncates; the server never stores a blank one, so omit `topic` rather than passing an empty string.
- Titles use the body size at medium weight. There is no larger header size.
