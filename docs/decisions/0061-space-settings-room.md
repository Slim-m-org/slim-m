# 0061 - Space settings gets a bigger panel and a wider cap for list panes

Date: 2026-10-08
Status: accepted

## Why this exists

The owner, 2026-10-05: "the entire space settings window can be increased in size, currently its compact causing issues with UI UX since its so busy, no reason we cant increase it a bit".

The visible window is not the app window.
Space settings is a `modalPage` (desktop-vs-mobile.md rule 5, a place with its own nav), a floating panel capped at `kModalMaxWidth` 860 by 720, and inside it the pane content was capped again at `kContentColumnMax` 720.
At 1280, 1440 and 1920 the panel was the same 860 wide, so a busy pane such as roles (list plus detail) only had about 620 beside the 240 nav.

## Decision

- `modalPage` takes optional `maxWidth` and `maxHeight`; the defaults stay `kModalMaxWidth` and `kModalMaxHeight`, so every other modal is unchanged.
- Space settings passes `kSpaceSettingsModalMaxWidth` 1100 and `kSpaceSettingsModalMaxHeight` 800.
  The height is still capped at 86% of the window, so a short window is unchanged.
- `SettingsPane.wide` opts a pane into `kSettingsWideContentMax` 880 (the room left beside the 240 nav).
  Only grids and lists set it: roles, channel permissions, emoji, invites, removed members.
  Forms and prose keep `kContentColumnMax` 720 so line lengths stay readable.
- `AppContentColumn` and `kContentColumnMax` are not changed; other screens share them.
- Personal settings keeps the standard panel; the owner's note was about Space settings.
- `kSettingsTwoPaneWidth` (800) is untouched: the panel only gets wider above the compact width, and a phone is still the whole window.
  Layout still follows width, never platform (rule 5, law 1).

## Amends 0013

0013 says a pane body is capped at the content column.
That stays the default; a list or grid pane may now opt into the wider cap.
