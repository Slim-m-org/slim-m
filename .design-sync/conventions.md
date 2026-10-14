# Building with slim-m

slim-m is a calm, self-hosted chat app (text, voice, screen share, a shared Voice Canvas). These React components mirror the Flutter client one for one, so a mock built from them is the real product.

## Setup

Wrap the whole screen in `SlimRoot` once. It sets `data-theme` (which switches every colour token), the base surface, IBM Plex Sans and 14px UI text.

```jsx
<SlimRoot theme="dark" style={{ minHeight: '100vh' }}>...</SlimRoot>
```

`theme` is `dark` (default), `light` or `black`. Outside a SlimRoot components fall back to dark tokens and light/black never apply. True black is every fill at #000 with hairlines carrying structure; never add shadows or lighter fills to compensate.

## Screens are built from composites

Build screens from the composites, not from raw rows: `AppShell` (slots `rail`, `header`, `content`, `members`, `banner`) holding a `ChannelRail`, a `ChannelHeader`, a column of `MessageRow`s with `DayDivider` / `UnreadDivider` / `TypingIndicator`, a `Composer`, and a `MemberList`. Voice: `CallDock`, `ParticipantGrid` of `ParticipantTile`s, `VoiceJoinBar`, `CallStrip`, `IncomingCall`. People: `MemberProfile`. Settings: `SettingsLayout` with `SettingsSectionCard`s of `SettingsToggleRow` / `SettingsSelectRow` / `SettingsEntityRow`. Status: `StatusBanner`.

## Desktop and mobile: width decides, never platform

`SlimRoot` is a size container and every composite reads its width, with the app's breakpoints: compact below 600, medium 600 to 999, expanded 1000 and up (settings goes two-pane at 800). So a phone mock is a `SlimRoot` about 390 wide and a desktop mock about 1280; the same components change shape on their own. `AppShell` at compact is one pane with the rail and members as drawers (`railOpen`, `membersOpen`); medium is rail plus content; expanded adds the member pane. Hover toolbars exist only on wide (`MessageRow hovered`); compact uses 44px touch rows. Where compact is a different surface, pick it with a prop: `MemberProfile presentation="popover"` on wide, `"sheet"` on compact; menus become a `Sheet` of touch `MenuItem`s. Give a SlimRoot an explicit width when it sits in a flex row.

## Styling idiom: CSS custom properties

No utility framework. Components style themselves; your own layout glue uses inline styles with these tokens (all defined in `styles.css` via `_ds_bundle.css`):

- Surfaces: `--surface-sunken` (rails), `--surface-base` (page), `--surface-raised` (cards, panels). Borders: `--border-subtle`, `--border-strong`, `--hairline` (a full `1px solid` shorthand).
- Text: `--text-primary`, `--text-secondary`, `--text-disabled`. Status: `--danger-text`, `--danger-border`, `--warn-text`, `--warn-soft`, `--status-online|away|dnd|offline`.
- Accent: `--accent-text` (accent as text or icon), `--accent-fill` + `--accent-on` (filled control and its ink), `--accent-soft` (tint fill), `--focus-ring`. The accent is for seven roles only: active channel, unread badge, mentions of you, live voice, unread divider, your own poll vote, the open member pane.
- Type: `--font-sans`, `--font-mono`; sizes `--text-micro` 11, `--text-caption` 12, `--text-ui` 14, `--text-body` 15, `--text-heading` 20, `--text-title` 24 with matching `--leading-*`; weights `--weight-regular|medium|semi` (never 700).
- Space: `--space-4|8|12|16|20|24|32|40|48|64`. Radius: `--radius-control` 6, `--radius-card` 10, `--radius-window` 16, `--radius-full`. Width: `--content-max` 720 (settings and admin column), `--message-max` 760 (the message column).
- Elevation is border-first: a hairline separates; only floating menus use `--shadow-menu` and dialogs `--shadow-float`. No gradients, no blur.
- Helper classes: `sm-label` (11px uppercase section label), `sm-mono` (Plex Mono for codes, channel names, timestamps), `sm-tabular` (digits that must not jitter).

## Where the truth lives

Read `guidelines/design-language.md` (the visual rules), `guidelines/desktop-vs-mobile.md` (layout responds to window width, never platform; every hover or right-click has a long-press twin on touch) and `guidelines/wording.md` (one word per action: Create, Add reaction, Remove; settings labels at most 5 words, descriptions one sentence of at most 12, never stating a default) before laying out a screen. Each component's `.prompt.md` says when to use it.

## Product rules

- Messages are rows, not chat bubbles. A message body is 15/1.45 in a column capped at `--message-max`.
- Failures show `ErrorState` in place with Retry; never a toast or snackbar. `Toast` is for confirmations only.
- Settings screens are `SettingsSectionCard`s holding `SettingsToggleRow` / `SettingsSelectRow`, inside a `ContentColumn`.
- No emoji as interface chrome; icons are `Icon` (or an `icon` prop) with these names only: hash, voice, voiceLobby, roomLocked, settings, members, restrictedChannel, back, add, search, info, chevronDown, chevronUp, chevronRight, pin, bookmark, moreVertical, moreHorizontal, dragHandle, send, reply, forward, thread, edit, retry, pending, failed, poll, code, webhook, smile, image, play, pause, attachFile, gif, download, share, clock, mic, micOff, headphones, speaker, speakerOff, camera, cameraOff, switchCamera, screenShare, screenShareStop, leaveCall, startCall, missedCall, expand, collapse, canvas, pen, eraser, undo, redo, note, pan, recenter, signOut, account, appearance, devices, devicePhone, deviceLaptop, deviceDesktop, notificationsOn, notificationsOff, mentions, unread, warning, highlight, danger, check, copy, link, chat, report, invite, shield, delete, revoke, dismiss, permissions, analytics, dock, popOut, externalLink (the full list is `iconNames`).

## Example

```jsx
<SlimRoot theme="dark" style={{ width: 1280, height: 760 }}>
  <AppShell
    rail={<ChannelRail spaceName="slim-m" categories={categories} user={me} />}
    header={<ChannelHeader name="general" topic="Everything that is not somewhere else" />}
    content={
      <>
        <DayDivider label="Today" />
        <MessageRow author="Mara Lindqvist" time="9:41" body="Pushed the new call dock to design-review." />
        <MessageRow author="Mara Lindqvist" time="9:42" grouped body="Looks right to me at 100%." />
        <Composer channelName="general" />
      </>
    }
    members={<MemberList sections={sections} />}
  />
</SlimRoot>
```

The same tree at `width: 390` is the phone layout.
