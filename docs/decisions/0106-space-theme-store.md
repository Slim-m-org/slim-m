<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0106 - A Space theme store, and a theme file you can export and import

Status: accepted
Date: 2026-11-03
Extends [0089](0089-soft-dark-and-forest-themes.md), [0101](0101-halloween-theme-and-backdrops.md) and [0104](0104-personal-background-picture.md).

## The ask

"Spaces theme store, allow users to import/export their theme configs space-wide scope."
The owner decided that a theme is a full theme: colour tokens, an optional backdrop effect and an optional backdrop picture.
Any member can publish one to the Space, anyone can apply any of them for themselves, and admins can remove them and pick the Space default.

## The theme file

- One JSON document, `format: "slimm-theme"`, `version: 1`.
- Fields: `name` (1 to 40 characters), `author` (display only, at most 40), `base`, `brightness`, `tokens`, `backdrop`.
- `base` names a built-in preset (`dark`, `light`, `trueBlack`, `catppuccin`, `softDark`, `forest`, `halloween`).
  It supplies what a file does not carry: the presence colours and the code colours, which already pass their own gates.
- `brightness` is `light` or `dark` and decides which Material mode the theme applies in.
- `tokens` carries all 19 core colours and nothing else: `surfaceSunken`, `surfaceBase`, `surfaceRaised`, `borderSubtle`, `borderStrong`, `textPrimary`, `textSecondary`, `textDisabled`, `accent`, `accentFill`, `accentOn`, `accentSoft`, `accentRing`, `focusRing`, `dangerText`, `dangerBorder`, `warnText`, `warnSoft`, `stripe`.
  Every one is required, written `#RRGGBB`.
  Only `accentRing`, `warnSoft` and `stripe` may carry alpha, as `#AARRGGBB`.
- `backdrop` is optional: `effect` (`halloweenWebs` or null) and `picture`.
  `picture` holds `data` (base64 of a PNG, JPEG or WebP, at most 2 MiB decoded), `dim`, `vignette` and `blur`, the three settings of 0104.
- Unknown keys are refused, so a file never carries something a reader silently ignores.

## What is validated

- The server and the client run the same checks, and a file that fails either is refused with the list of problems.
- Every colour parses.
- The same floors as the built-in theme tests (`contrast_test.dart`, `component_boundary_contrast_test.dart`):
  primary text, secondary text and accent text reach 4.5:1 on all three surfaces;
  `accentOn` reaches 4.5:1 on `accentFill`, and accent reaches 4.5:1 on `accentSoft`;
  danger and warning text reach 4.5:1 on all three surfaces;
  `borderStrong` reaches 3:1 on all three surfaces;
  disabled text is quieter than secondary text.
- Size caps: the whole document at most 3 MiB on the wire, the picture at most 2 MiB, and a Space holds at most 50 store themes.
- The picture is sniffed from its bytes, not from a declared type, and must be a still image.

## How a picture is stored

The picture is a BLOB on the store row, not an `attachments` row.
The emoji path (0016, 0017) shows what sharing the attachments table costs: the orphan sweep, the export and the account deletion each need an exclusion for it.
A theme picture is capped at 2 MiB and 50 themes (5 per author), at most 100 MiB, and belongs to nothing else, so a column keeps it out of all three.
It is served by `GET /space/themes/{id}/picture` with an immutable cache header, keyed by the theme id.
Applying a theme with a picture hands the bytes to the personal background of 0104 on that device, so dim, vignette, blur and the contrast floor work as they already do.

## Permissions

- Any member publishes: `POST /space/themes`.
- Anyone applies any store theme for themselves; applying is local and calls nothing.
- The author or a member with `MANAGE_SERVER` removes a theme: `DELETE /space/themes/{id}`.
  Anyone else gets 403.
- Only `MANAGE_SERVER` sets the Space default: `PUT /space/default-theme`.
  Removing the default theme clears the default.
- Removals and default changes are audit-logged like other admin writes, whoever removes the theme.
  Publishing is not logged.

## The Space default

- A new choice, `Space default`, is the new fallback.
  It resolves to the Space's default theme when there is one, and behaves as `System` when there is none.
- A member who picked anything else keeps it.

## Client

- Appearance gains a "Theme store" card: the Space's themes with a swatch strip and backdrop thumbnail, Apply, and for admins Remove and "Make Space default".
- The card also exports the current theme to a `.json` file, imports one (problems shown inline), and publishes.
- A custom theme is one more `AppThemeChoice`, `custom`, held on the device as the document it was applied from.
- Export and import go through the file picker, which downloads on the web, saves on desktop and uses the system save and open UI on phones.

## Cost

A Space can now carry 50 pictures in its database.
The caps bound it, and the store is the only place a member can add one.

## The editor (built 2026-11-04)

The theme editor finishes what the file format promised: you can now make a theme, not just move one around.

- A page above Themes inside the Appearance pane (`/settings?pane=appearance&page=new-theme`; the old `/settings/themes/edit` redirects there), so the settings nav stays beside it (rule 5).
  The draft's preview is pinned under the header (the short strip below 480 of content), one column of cards scrolls under it (Details, Main colours, Contrast, All colours), and one pinned footer holds Save and the primary Save and apply at every width.
  A window too short for the pin lets the preview scroll away instead.
  While checks fail, the footer says how many, links to Contrast and offers Fix all.
- It starts from any built-in ("Customise"), any Space theme ("Edit a copy"), a Mine entry ("Edit") or the "Start from" row inside the editor.
- Main colours are Background, Accent and Text.
  The colours linked to each (sunken and raised; fill, ring and focus; secondary and disabled), and the warning tint to Warning text, follow by the same HSL change until they are edited themselves.
  Links live only in the editor session, every session starts with all of them on and Start from turns them back on; the file never stores them, since the format refuses unknown keys.
- The 19 tokens are grouped as Surfaces, Text, Accent, Borders, Status and Other: a two-column grid of tiles from 480 of content, and six collapsible groups with each opacity slider under its colour below it.
  The picker is the design system's `AppColourPicker`, inline from 480 of content and in `showAppColourPicker` below it, both previewing live through `onChanged`, committing with Done and reverting with Cancel.
  It says what a colour also sets and checks contrast live as it moves; the three tokens that may carry alpha get their opacity slider inside it.
- The contrast floors are data (`themeContrastChecks`) and the parser reports the same sentences.
  Failing floors are grouped by the colour to change, each with what to do and a Fix that clears all of that colour's checks; "Fix all" covers every one, and Save, Publish and Export refuse while any fails.
- "Mine" is a list kept on the device (`slimm.appearance.my_themes`, at most 50), apart from the theme in use.
  Pictures are not kept in Mine: the editor does not edit them, and a picture only travels with a theme applied from the store.
  Importing a file with a picture saves the colours and drops the picture.
- Publish sends the draft under the member's display name and shows the server's own sentence for the 5-per-author and 50-per-Space caps.
- Import and Export use the existing wire format through the file picker; an import that fails the checks is refused with the first three problems.
- Not built: "accent from my background picture" (0104), which needs palette extraction and is not cheap.
- No migration and no server change.

## The gallery (built 2026-11-16)

- Themes is a grid of small copies of the app, each painted in its own theme's tokens: three across beside the nav, two on a phone, and one tap applies.
- The card in use carries the accent ring and "In use" whatever its source, read from the source stored with the custom slot (`slimm.appearance.custom_theme_source`).
- Built-ins get a pencil for Customise and System gets nothing; Mine and Space cards get one menu that right-click, a long-press and the kebab all open, and Delete and Remove confirm.
- A theme in use that nothing keeps (applied from a file, or from a Mine or Space entry that is gone) is a Not saved card first in Mine, with Save to Mine.
- A Space theme that fails a contrast check or cannot be read says so on its card, and Edit a copy opens one that fails only contrast.
- Following the Space default is not a gallery row: the default's card is the one in use while it is followed.

## The Appearance page (built 2026-11-16)

- Appearance opens on a Theme card: a live preview of the theme in use (System split across a diagonal), its name and where it came from or Not saved, one main action (Customise, Edit or Save to Mine) and Browse themes into the gallery.
- Recent (`slimm.appearance.recent_themes`, per Space) shows the theme in use and the last ones applied, one tap each.
  Applying a theme records the one it replaced as well, so a theme chosen before Recent existed is not lost on the first switch.
  With a pointer, resting on a tile previews it in the card's preview only; touch applies at once.
- Following the Space default is a switch on that card, shown only while the Space has a default; turning it off keeps the same theme as a Space theme, so nothing repaints.
- When a theme's picture settings are applied, `slimm.appearance.background_from` (device-wide, like the background) names the theme, and the Background card says so until one of its controls is changed.
