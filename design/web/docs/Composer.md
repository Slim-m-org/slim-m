---
category: Chat
---

# Composer

The message input: an optional slow-mode notice, staged attachments and reply banner above a raised bar holding the field and its actions. The hint reads "Message #channel" with the channel name in mono.

## Wide vs compact

Decided by the width of the nearest `SlimRoot` (`composer_action_bar.dart` reads `AppTouchTargets`, which is width, not platform).

- 600px and wider: 20px side gutter, a 30px field and pointer-size buttons. The bar shows Attach a file, the field, Create a poll, Insert code, Insert emoji or a GIF, and Send.
- Below 600px: 10px gutter, a 44px field and 44px hit targets. Attach, poll and code fold into one "More actions" button on the left (it opens a sheet, a separate mock). The bar shows that button, the field, the emoji button and Send. Send is always drawn, only disabled.

The app's field stays 15px at both widths; the design doc's 16px and h48 note is not in the Flutter source, which wins.

## Usage

```jsx
<SlimRoot style={{ width: 760 }}>
  <Composer channelName="design-review" value="Spacing fixed." replyTo={{ author: 'Mara Lindqvist', snippet: 'Check the ring spacing' }} />
</SlimRoot>
```

## Rules

- Send is disabled while the draft is empty with nothing staged, or while `slowModeSeconds` is above 0. Slow mode shows a persistent danger-outlined notice above the bar, never a snackbar.
- `replyTo` draws the sunken banner "Replying to Name" with a one-line snippet and a Cancel button. Cancel is always reachable.
- `attachments` become 40px-thumb tiles: `uploading` shows percent and a 3px bar, `failed` turns the border danger with the reason and a Retry glyph. Every tile has a remove control.
- Controls are icon buttons with labels; the bar is top-aligned so icons do not drift when the field grows to six lines.
