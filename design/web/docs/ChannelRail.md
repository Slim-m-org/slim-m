---
category: Shell
---

# ChannelRail

The sunken channel list on the left: space header, a search trigger, category sections with text and voice rows, and the footer with your presence and mic, headphone and settings buttons.
Use it as the `rail` slot of `AppShell`; it takes channels, categories, voice members and the current user as plain data.

## Width

The rail fills its container, so the shell decides how wide it is: 248px docked on expanded, 240px on medium, the drawer width (304px) on compact.

- 600px and up: 30px rows, the Ctrl+K hint in the search trigger (hidden when the rail is under 224px).
- Under 600: 44px rows and section headers, no keyboard hint. The same widget sits in the left drawer.
- Under about 216px wide the footer drops the name and keeps the buttons.

## Rows

- Selected: accent-soft fill with a 2px marker on the left.
- `unread`: primary ink, medium weight and a dot. `mentioned`: the same with an accent diamond, the only marker that survives `muted`. `muted` dims the glyph and trailing marks.
- Voice rows show who is in the call under the row: 20px avatars with the speaking ring, a name, and mic-off, camera or screen share glyphs. Eight names show, then "+N more".
- `joinMuted` adds a mic-off glyph at the row end, `userLimit` shows present/limit, `lobby` swaps the speaker for the lobby glyph, `restricted` for a lock.
- A category with an empty `name` has no label. `collapsed` folds its rows.

## Usage

```jsx
<ChannelRail
  spaceName="slim-m"
  user={{ name: 'Mara Lindqvist', status: 'online', inCall: true }}
  categories={[
    { id: 't', name: 'Text channels', channels: [
      { id: 'general', name: 'general', selected: true },
      { id: 'design-review', name: 'design-review', mentioned: true },
    ] },
    { id: 'v', name: 'Voice channels', channels: [
      { id: 'movie-room', name: 'movie-room', kind: 'voice', participants: [{ name: 'kiki', speaking: true }] },
    ] },
  ]}
/>
```

- Mic and headphone buttons are disabled unless `user.inCall` is set.
- `updatePending` dots the settings gear.
- Selecting a row in the compact drawer closes the drawer; do that in your own state.
