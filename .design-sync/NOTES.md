# design-sync notes (slim-m)

- The shipped design system is Flutter (`client/packages/design_system`). claude.ai/design needs React, so `design/web` is a React mirror of it, written from the Flutter source (the July design export zip was a cross-check only). When a Flutter widget changes, its React twin must change with it, or the design agent builds with stale parts.
- Build: `cd design/web && npm ci && npm run build` produces `dist/` (esbuild ESM entry, tsc `.d.ts`, `dist/styles.css` = tokens + base + every `src/styles/components/*.css`). Then run the converter with `--node-modules design/web/node_modules --entry design/web/dist/index.js` from the repo root.
- `src/icons.ts` is generated from `app_icons.dart` by `npm run icons`; rerun it when AppIcons changes. All 153 app icons map to lucide-react 1.47.0 names.
- Fonts are the Plex TTFs the Flutter client ships (`client/packages/design_system/fonts`), wired through `cfg.extraFonts` -> `design/web/src/styles/fonts.css`.
- Token gotcha: a custom property that references another (`--hairline: 1px solid var(--border-subtle)`) resolves where it is declared, so declaring it only on `:root` froze it at the dark value inside light and black themes. It is now declared on `:root, [data-theme]`. Any future composite token needs the same treatment.
- Shipped values that differ from the July design export (code wins): modal scrim is black 54% (Flutter's `black54`), not 62%; the content column is 720px (`kContentColumnMax`), not 760.
- Playwright: the cached chromium here is build 1228, which pins `playwright@1.61.1` in `.ds-sync`.
- Previews render inside `SlimRoot theme="dark"` with 16px padding (`cfg.provider`).
- Groups come from `category` frontmatter in `design/web/docs/<Name>.md` (Foundations, Core, Brand, Forms, Settings, Surfaces); those docs are also each component's `.prompt.md`.
- Groups (the `category` frontmatter) are read only by a full `package-build.mjs` run; `preview-rebuild.mjs` keeps whatever group the last full build assigned, so a scoped wave shows everything under "general" until the next full build.
- BrandLattice draws its accent square at a fixed spot (column 4, row 12, about x 126 / y 350); a panel shorter than about 380px shows only faint dots. Previews and its doc use 420px or taller.
- Avatar tints hash from the name, so a size sweep with one name looks uniform; vary names when the tint matters.
- A Menu inside a Sheet needs `style={{ width: '100%' }}`; Menu defaults to 250px.
- Slider `disabled` is not dimmed. That matches Flutter, whose custom slider shapes paint their own colours whether or not `onChanged` is null.
- Emoji in previews (Chip reactions) are `\u{...}` escapes.
- Sheet body padding is 8px so touch rows (which pad themselves) line up with the 16px title; plain text inside a Sheet needs its own 8px horizontal padding.

## Known render warns

- `[TOKENS_MISSING]` for `--sm-input-max-lines`, `--sm-slider-pos`, `--sm-speaking-color`, `--sm-speaking-bg` (and other `--sm-*`): component-local custom properties set inline per instance, not tokens. Expected.

## Re-sync risks

- `design/web` is hand-ported from Flutter. Nothing checks that it still matches; a Flutter component change (sizes, variants, tokens) silently leaves the React twin stale. Recheck the touched component on every sync, starting from `git log client/packages/design_system` since the last one.
- `src/styles/tokens.css` is transcribed by hand from `app_tokens.dart` and friends. Same risk; diff the Dart token files since the last sync.
- `src/icons.ts` is generated; rerun `npm run icons` before building when `app_icons.dart` changed.
- The core batch wrote its docs from the React source and JSDoc, not from the Flutter originals; spot-check them against the Dart widgets when touching those components.
- The playwright pin (1.61.1) depends on the locally cached chromium 1228.
