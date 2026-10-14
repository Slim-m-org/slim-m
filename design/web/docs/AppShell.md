---
category: Shell
---

# AppShell

The layout frame every signed-in screen sits in: slots for `rail`, `header`, `content`, `members` and an optional `banner`.
Use it once per screen and put a ChannelRail, ChannelHeader, your conversation and a MemberList in the slots. Give its SlimRoot an explicit height.

## Width

Width decides, never platform, and a resize across a breakpoint slides panes (180ms) rather than swapping them.

- Expanded, 1000px and up: rail (248px), content, member pane (236px) side by side.
- Medium, 600 to 999: rail (240px) and content. The member pane docks only from 836px wide (rail, pane and a 330px minimum transcript must fit); below that it is a right drawer, opened with `membersOpen`.
- Compact, under 600: content alone. `railOpen` draws the rail as a left drawer (304px, at most the width minus 56px) and `membersOpen` the members as a right drawer (236px), each over a scrim; `onDismiss` fires when the scrim is pressed.

## Usage

```jsx
<SlimRoot style={{ width: 1100, height: 560 }}>
  <AppShell
    rail={<ChannelRail spaceName="slim-m" categories={categories} user={user} />}
    header={<ChannelHeader name="general" />}
    content={
      <>
        <MessageRow author="Mara Lindqvist" time="9:41" body="Pushed the new call dock." />
        <Composer channelName="general" />
      </>
    }
    members={<MemberList sections={sections} />}
  />
</SlimRoot>
```

- `membersDocked={false}` hides the docked member pane, the way the header toggle does. It does not affect the drawer.
- `banner` spans the whole shell and pushes it down (desktop-vs-mobile rule 6); pass a StatusBanner.
- Only one drawer should be open at a time; the scrim sits over the content, not over an open drawer.
- Drawers are decoration only in a mock: they take no focus trap or swipe, so state them with the props above.
