# 0013 - One container system for settings and administration

Date: 2026-08-10
Status: accepted

## Why this exists

The owner, on the settings surface: "space settings and personal settings look very difficult UI wise, we need to decide on a container for each of these UI components and cleanup this mess", and then "setting ui on space and personal really looks like shit, so overhaul it".

`docs/reports/screen-review/settings.md` had reviewed this same area a day earlier and rated personal settings "clean across all three lenses, no findings".
Both are correct, and the gap between them is the finding.
That review checked each screen for correctness in isolation: does its copy say what is true, does its gating match the server, does it handle its own empty and error states.
Nobody checked whether the screens use a consistent container idiom *with each other*.
A per-screen review is structurally incapable of seeing that, because every one of the six idioms below is defensible on the screen it appears on.
It is only when you cross from one screen to the next that the surface reads as unfinished.

## The inventory

Six different ways to express "a group of related settings", across twelve screens that sit one tap apart from each other.

1. **`SettingsSectionCard`**: a prominent header *outside* a bordered card holding rows.
   Used by every personal settings pane and by `SpaceSettingsSection`.
2. **`AppCard(title:)`**: a small uppercase micro-label header *inside* the card, with its own hairline under it.
   Used by `channel_overwrites_screen` ("CHANNEL", "ROLE"), `report_card` ("REPORTED USER"), `analytics_charts`, `emoji_upload_card`, `invites_screen`'s create form.
   This is the same semantic job as (1) - naming a group of rows - rendered completely differently.
   ~~`report_card` and `analytics_charts` are named here as offenders and left that way.~~
   Corrected 2026-08-10: both were still on `AppCard(title:)` when this record first shipped, found by two independent reviewers checking the inventory against `main` rather than trusting it.
   `admin-reports-desktop-light.png` was byte-identical to `main` while every sibling admin screen had already moved, which is a half-converted area reading as a bug rather than a style choice.
   Both are `SettingsSectionCard(title:)` now.
   Converting `report_card` surfaced a real collision the old `AppCard(title:)` had hidden by accident: its title uppercased to "REPORTED USER" while `ReportLabeledValue`'s own inner label read "Reported user", so the two never string-matched even though they said the same thing.
   `SettingsSectionHeader` does not uppercase, so both became the literal same string and `report_card_test.dart` caught it (`findsOneWidget` found two).
   The inner label is `'Subject'` for a user report now, distinct from the card's own title rather than a duplicate of it - `'Reported author'` for a message report already had no such collision, since it names *who wrote it*, not the card's own subject.
3. **A bare `AppCard` per list item**, each hand-rolling `Row(leading?, Expanded(Column(title, subtitle...)), actions)` with an `AppErrorState` appended.
   Five independent copies: `roles_screen`, `invites_screen`, `emoji_screen`, `removed_members_screen`, `categories_screen`.
   A list of three roles is three separate bordered boxes floating with gaps, where the same three items in Space settings would be three rows inside one box.
   ~~`categories_screen` is named here and left unconverted.~~
   Corrected 2026-08-10: it also independently re-implemented the inset rule below, passing `SettingsScreenScaffold(padding: EdgeInsets.zero)` and its own `ListView(padding: EdgeInsets.all(AppSpacing.s16))`, landing back on the same 16px the frame would have given it for free.
   That is live evidence of the exact drift this record exists to close, sitting untouched next to its already-fixed siblings.
   Its create form and its per-category rows are inside one `SettingsSectionCard` each now, and the screen takes the frame's own default inset.
4. **`SettingsGroupHeader` plus loose uncontained rows.**
   `app_info_section` alone: the one personal-settings section with no bordered box at all, sitting directly on the pane background beside siblings that all have one.
5. **A local `_SectionHeader` and no container whatsoever.**
   `voice_settings_screen`, for all five of its sections. The local header duplicated `SettingsSectionHeader`'s look while omitting its `Semantics(header: true)`, so none of those headings were announced as headings.
6. **`ListView.separated` with a raw Material `Divider` and no card.**
   `debug_log_screen`, which also built its own `Scaffold`/`AppBar` rather than the shared frame, losing the named back-button tooltip every sibling carries.

Three different horizontal content insets follow from that: 32 for personal and Space settings (the screen frame's 16, plus another 16 `SettingsSectionCard` added on top), 16 for every admin screen, and 0 for the debug log.
Sibling screens indenting their content by three different amounts is the specific thing that reads as "difficult" when you move between them, and it is measurable in the capture PNGs rather than a matter of taste.

Two smaller inventories in the same area:

- **Three shapes for a toggle row.** `AppListRow(trailing: AppToggle(...))` in `appearance_settings_section`, and a hand-rolled `Padding(Row(Expanded(Text), AppToggle))` in `voice_settings_screen` (twice) and `personal_status_sections`.
  ~~Three.~~ Corrected 2026-08-10: `analytics_screen._ToggleCard` was an uncounted fourth, `AppCard(Row(Expanded(Column(Text, Text)), AppToggle))`, missed by the original sweep and found by a reviewer.
  It is a `SettingsToggleRow` inside a `SettingsSectionCard` now, the same as the other three.
- **Two competing scaffolds**, which is correct and stays: `SettingsScreenScaffold` (a single scrolling screen) and `SettingsPanesScaffold` (a nav beside a pane). Personal settings genuinely is a different navigation shape from a single admin screen. What was wrong is that the two did not agree on anything *below* the frame.

## The decision

**A settings or administration screen body is a stack of `SettingsSectionCard`s. Nothing else is a container.**

The vocabulary, in full. Each entry names when to reach for it, so a future contributor picks rather than invents.

| Component | Use it for |
|---|---|
| `SettingsSectionCard` | Any group of related settings or items. Title outside, bordered card inside. Optional `description`. |
| `AppListRow` | A row that navigates somewhere or opens a picker. Single-line by design. |
| `SettingsSelectRow` | A row stating its current value and opening a sheet to change it. |
| `SettingsToggleRow` | A setting you turn on or off. Wraps its label. |
| `SettingsEntityRow` | One administered item in a list: a role, an invite, an emoji, a removed member. Headline, optional badge, caption lines, trailing actions, its own inline error slot. |
| `SettingsNotice` | A surface with nothing to show, and the reason why. |
| `SettingsAbsentValue` | One optional field that has no value, inline where the value would be. |

And the rule that keeps the insets from drifting apart again: **horizontal inset is owned by the screen frame, never by a section.**
`SettingsScreenScaffold` and `SettingsPanesScaffold`'s pane body each already pad by `AppSpacing.s16`. `SettingsSectionCard` used to add another 16 on top, which is where the 32-versus-16 split came from. It adds none now.

## What was rejected

**Converting the admin lists to `AppListRow`.**
The obvious unification, and it loses information. `AppListRow` is deliberately single-line and fixed-height, and ellipsizes its label to hold that, because a rail of channels needs an even rhythm. An invite carries a code, a state badge, a uses-and-expiry line and a role grant: four pieces over three lines. `SettingsEntityRow` is a sibling of `AppListRow`, not a variant of it, and the two are kept apart on exactly that axis.

**Making every toggle an `AppListRow(trailing: AppToggle(...))`.**
Same failure, smaller. Three of these settings are whole sentences - "Play a sound when someone joins or leaves a call" - which fit a desktop pane and do not fit beside a toggle at phone width. Truncating the middle of a sentence that explains what a switch does is worse than a row of uneven height, so `SettingsToggleRow` wraps.

**Putting the new components in the design system.**
They are compositions of design-system primitives expressing *this app's* settings conventions, not primitives in their own right. `SettingsScreenScaffold`'s own library doc already draws this line for itself, and this follows it: a component library has no business knowing that an administered entity carries an inline failure banner. `AppCard`, `AppBadge`, `AppErrorState` and `AppToggle` stay where they are and these compose them.

**Retiring `AppCard(title:)`.**
It stays in the design system and is still right for a genuinely nested panel - a floating canvas window, a card sitting inside a screen that is not itself a settings surface.
~~a chart card~~ was named here as a second example and was wrong: `analytics_charts.dart`'s three chart cards are a settings surface (`AnalyticsScreen`, reached from Space settings, MANAGE_SERVER-gated), and sat on `AppCard(title:)` unconverted until the correction above.
They are `SettingsSectionCard(title:)` now like every other card in this area.
What changed is that settings does not use `AppCard(title:)` at all, because in settings it was competing with `SettingsSectionCard` for the same job; the surviving examples are outside settings entirely, not inside it doing a different job.

**Converting the Space settings section gate to per-channel permissions.**
Decision 0011 explicitly decided the outer Space-settings section gate stays on base permissions, and reopening that here would contradict a decision two days old for a cosmetic reason. The "Channel permissions" row's own gate had already been widened to include a channel-scoped `MANAGE_ROLES` (`canManageRolesAnywhere`). The residual is the reverse case, a caller holding base `MANAGE_ROLES` who is denied it in one channel by an overwrite: they can still open the screen, pick that channel and be refused on submit. That is disclosed in copy rather than pre-computed, matching the gate-then-surface pattern the review named as this area's most consistent strength.

## The rule a future contributor follows

Before adding a container to a settings or admin screen, pick from the table above.
If none of them fits, that is a finding worth writing down rather than a licence to hand-roll a sixth idiom: say what does not fit and extend the vocabulary deliberately.

The specific mistakes that produced this mess, so they are recognisable next time:

- Reaching for `AppCard` directly instead of `SettingsSectionCard`, because `AppCard` is what the design system exports and is one import closer.
- Writing a local `_SectionHeader` because the shared one was in a file you were not already importing. That is how `voice_settings_screen` lost its heading semantics.
- Adding padding to a section because it looked too tight, without checking whether the frame already added some.
- Hand-rolling a row shape for one screen. Five screens did that independently and all five agreed by luck on the caption style, which is not the same as agreeing structurally.

## Fixed after review, 2026-08-10

Two independent adversarial reviewers, then a third pass reconciling both, found four more things beyond the incomplete conversion documented above.

**`SettingsEntityRow.actions` had two incompatible calling conventions, reproduced inside the fix meant to close exactly this class of drift.**
`actions` was `List<Widget>`, and `build()` unconditionally wrapped it in the reserved-slot row.
The reserved-slot shape needs nullable elements to reserve an empty position, which `List<Widget>` cannot carry, so `roles_screen` and `invites_screen` each built their own reserved-slot row and passed it as the sole element, nesting one inside the other - harmless visually (Flutter tolerates a redundant `Row`), but two conventions for one parameter with nothing telling a new caller which theirs needed.
`settings_entity_row_test.dart` had enshrined the double-wrap as the documented shape, so the test would not have caught a third call site copying it.
`actions` is `List<Widget?>` now, callers pass a flat list, and the reserved-slot row moved onto `SettingsEntityRow` itself as a private implementation detail (`_SettingsEntityActions`) rather than a second publicly constructible widget a caller could wrap around its own list.

**`SettingsSectionCard.action` had zero production callers, and its one plausible one had already declined it for a reason that generalises to every async-gated card.**
`roles_screen`'s "New role" button stayed on the scaffold's own `AppBar` rather than this slot, with a comment saying why: the card only renders once the role list has loaded, and creating a role has to stay reachable while it hasn't.
That reasoning is not specific to roles - any `SettingsSectionCard` sitting inside an `AppAsyncView`'s `data:` builder has the identical problem, which is most of them.
Nothing else in the app ever reached for it either.
A speculative slot in a vocabulary table reads as endorsed, which is worse than not having it, so it is deleted rather than kept for a caller that was never going to arrive: `SettingsSectionHeader` lost `action` along with it.
`SettingsSectionCard(title: null, description: ...)` used to silently drop the description too, since the header that carries it only builds when `title` is non-null; that is now an `assert` rather than a silent loss, with a test for it.

**Two of the five vocabulary components had no contract test of their own**, `SettingsNotice` and `SettingsAbsentValue`, both reached only indirectly through screen tests that assert nothing about what the widgets themselves guarantee.
`settings_notice_test.dart` covers both directly now: the message/detail/icon contract for the first, and the muted-italic rendering for the second.

## What this does not settle

Whether `SettingsPanesScaffold` and `SettingsScreenScaffold` should eventually be one thing.
They are genuinely different navigation shapes today and the split is deliberate; a single settings surface that adapts between "one scroll" and "nav plus pane" is a larger question than a container vocabulary and nobody has asked for it.

~~Whether the six-idiom drift would have been caught by a mechanical gate.~~
~~A gate on "no bare `AppCard` under `screens/admin/`" would have caught idiom 3 and none of the others, and would have false-positived on the legitimate chart cards. The honest answer is that this class of drift is caught by looking at the rendered screens side by side, which is what `scripts/ui-capture.sh` is for, and it went uncaught because nobody had looked at the whole set in one sitting.~~
Narrowed and partly built, 2026-08-10.
The six-idiom drift as a whole is still a rendered-screens question, not a source-scan one - "does this card look like the others" is not a property `grep` can see.
But the one rule this record actually commits to, horizontal inset is owned by the frame and never by a section, *is* a source-scan question, the same shape `type_scale_literal_test.dart` already gates an off-scale `fontSize:` literal with, and it would have caught `categories_screen.dart`'s reimplementation directly rather than waiting for a reviewer to read the file by hand.
`settings_frame_inset_test.dart` reads every `SettingsScreenScaffold(...)` call under `lib/src/screens/` for an explicit `padding:` argument or a `Padding` wrapped around its `child:` before the frame sees it, with a named one-line-why allowlist for `reports_screen.dart`'s genuine need to own its own paginated `ListView`.
Deliberately not attempted: `SettingsPanesScaffold` takes no `padding` parameter at all, so the only way a pane could re-derive its own inset is inside a `SettingsPane.builder` closure, which may be declared anywhere and is not something a scan of the scaffold call site can see - a real residual, left unenforced rather than approximated with a check that would either miss it or false-positive on unrelated `Padding` widgets a pane's own content legitimately uses.

## Addendum, 2026-09-28: hierarchy inside the container

The container vocabulary fixed the idiom, but the panes still read flat because the levels inside it were not distinct.
Four concrete causes, found by rendering every personal pane at phone and desktop width in both themes.

1. `AppListRow` sized its `meta` as a `Flexible` beside the `Expanded` label, so the two split the free space in half and the value floated mid-row instead of against the trailing edge.
   Toggles sat at the right edge and selects did not, and the halved label truncated ("Attachment preview ...") with room to spare.
   `meta` is sized to its text and capped at half the row now.
2. Select and navigation rows read their label in `text-secondary` beside toggle rows in `text-primary`, so one card carried two greys.
   `SettingsSectionCard` scopes its rows to `text-primary` through `AppStrongLabelScope`.
3. Rows in a list-of-rows card had no rule between them (`divided: true` now draws a hairline), and an untitled card sat 24dp higher than a titled one, so stacked untitled cards touched and the first block jumped as you moved between panes.
   An untitled card now leaves the same 24dp a titled header does.
4. At two-pane width nothing in the pane named the pane, only the selected nav row.
   `SettingsPanesScaffold` renders the pane label as a `heading` step above its sections, giving three levels (pane, section, row).
   This supersedes `settings_taxonomy_test.dart`'s earlier "the nav row is the only place the name appears": a section header still may not restate the pane name, but the pane's own heading does.

## Addendum, 2026-10-16: the redesigned settings window

The owner asked for personal settings to follow a new design ("personal settings redesign, align to this"), exported as thirteen desktop frames.
It keeps this record's vocabulary, a stack of titled section cards holding rows, and changes the metrics inside it.

- `SettingsSectionCard` lays its children edge to edge with a full-width `SettingsHairline` between every child and no inner padding.
  The padded card (8 inside, an inset rule only when `divided`) is gone: personal settings, Space settings, channel settings and call stats were all moved over in the same change, at the owner's request ("align the space settings to the new personal setting styling ... cleanup old code").
- Rows inside a card are 56 tall with a 16 inset and square hover, set once by `AppCardRowScope` in the design system so `AppListRow`, `SettingsToggleRow`, `SettingsSelectRow` and `SettingsEntityRow` cannot drift apart.
- Non-row content (fields, a preview) sits in a `SettingsCardBlock` at the card's 16 inset, and a setting that belongs to the row above it is a `SettingsSubRow`, indented 32 on a tint halfway between `surface-base` and `surface-raised` rather than a new token.
- Section headers sit 28 below the previous card, with 2 between title and description and 10 to the card.
- `SettingsPanesScaffold` drops the app bar across both columns at two-pane width: the nav carries the way back and the title on `surface-sunken`, its group labels are uppercase mono (spoken in their written case), and the pane has its own heading row with a close button and a 32/24/40 inset.
- The design's 13px and 16px text map to the scale's 12 (caption) and 15 (body) steps; no off-scale size was added.
