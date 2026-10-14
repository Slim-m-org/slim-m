# Authoring a component

This package is a React mirror of the Flutter design system in `client/packages/design_system/lib/src`.
It exists so the claude.ai/design agent can build mocks with the same parts the app ships.
The Flutter source is the truth; this package follows it.

## Sources, in order of authority

1. The Flutter widget (`client/packages/design_system/lib/src/components/...` or `client/packages/app/lib/src/widgets/...`): sizes, paddings, radii, colours, states, variants, prop names.
2. The token files in `src/styles/tokens.css`, transcribed from `app_tokens.dart`, `app_typography.dart`, `app_metrics.dart` and `app_motion.dart`.
3. The July design export at `~/.slimm-scratch/dl/dszip/components/**` (and `guidelines/RULES.md`): a cross-check only. Where it disagrees with the Flutter code, the code wins; note the disagreement in your report.

## Shape of a component

- `src/components/<Name>.tsx`: one exported function component plus its `<Name>Props` interface (exported). Variant unions are exported types too (`export type ButtonVariant = ...`).
- `src/styles/components/<name>.css`: the component's classes. Every class starts with `sm-<name>`, BEM-ish: `sm-button`, `sm-button--primary`, `sm-button__label`. First line is a comment naming the Flutter source file.
- Look at `src/components/Button.tsx` and `src/styles/components/button.css` and match them.

## Rules

- Colours, sizes, radii, fonts and durations come from `var(--...)` tokens in `tokens.css`. No raw hex in component CSS except where the Flutter source itself hard-codes a value; then keep the literal and say so in a one-line comment.
- Props mirror the Flutter constructor where it makes sense in React: same names (`label`, `variant`, `size`, `icon`, `disabled`, `busy`, `selected`), same enum values. Drop Flutter-only plumbing (focusNode, semanticLabel becomes `aria-label`, touch density).
- Icons: `import { Icon, type IconName } from './Icon'` and take `icon?: IconName`. Names are Flutter's `AppIcons` names (see `src/icons.ts`).
- Pass through the root element's HTML attributes (`...rest`, `className` merged) the way Button does.
- No emoji anywhere. No em dash in comments or strings.
- Comments explain why, never how, and are one line. The component gets a one or two sentence JSDoc saying what it is and when to use it; that JSDoc becomes the design agent's summary, so make it useful.
- Interactive states: press, focus-visible (2px `--focus-ring` outline), disabled (the Flutter opacity). Hover only where the Flutter widget has one.
- Controlled components (Toggle, Input, Slider, SegmentedControl) take `value` + `onChange`; they must render sensibly with no handler (static mocks).
- Keep each file under 300 lines.

## Do not touch

`src/index.ts`, `build.mjs`, `tokens.css`, `base.css`, `package.json`, other agents' files.
Need a new token or an export? Put it in your report instead.
