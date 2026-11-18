# Errors and status: where each one goes

The owner's screen review (2026-11) asked why forms showed red banners "instead of subtext under the input boxes like during signups", and said of the canvas banners that "they don't fade away, they push other ui elements around and they just don't feel like proper error handling in the scenario they are in".
This is the rule that answers both.
`desktop-vs-mobile.md` rule 6 points here; decision 0018 still holds that an error is never a toast.

## The rule

1. **A field's error sits under the field.**
   A value the client refuses, and a value the server refuses, both go under the input that holds it as `AppInput.errorText`: the field gets the danger border and one red line beneath it.
   That includes server answers about the value: an unreachable address under Server, an unusable invite or reset code under the code, a wrong password under the password.
   Editing the field clears its own error.
   A field with a standing note passes it as `AppInput.helperText`, which the error replaces, so the form keeps its height.
2. **A failure no field owns stays at the form.**
   One red line above the submit button where that button is already the retry (sign-in, Redeem an invite), or a boxed `AppErrorState` where the failure carries its own Retry or Dismiss.
   It persists until dismissed or until what caused it changes; it never fades on a timer.
3. **Transient status floats and fades.**
   Status the user did not ask for and that resolves by itself (retrying, saving, a region drawn at a cap) floats over the surface instead of taking layout, so nothing moves when it comes or goes.
   It fades in and out over `AppMotion.base`, and snaps under reduce motion.
   A surface shows one at a time, the most urgent, never a stack.
   It sits next to what it is about: the canvas floats `CanvasNotice` just above the dock whose tools and call controls it concerns, and says hidden ink beside the zoom readout with a tap to zoom in.
   An API failure on such a surface keeps rule 2's persistence; only its rendering is an overlay pill rather than an in-flow box.
4. **A banner is only for a page-level state the user must act on.**
   An update to install, a new sign-in to confirm, rules to accept, a role being viewed as: these stay in flow as `AppCallout` or `AppErrorState`, with the button that resolves them.
   If nothing on the banner can be done, it is status (rule 3) or it should not be shown.

## Where the code is

- `AppInput.errorText` and `helperText`: `client/packages/design_system/lib/src/components/forms/input.dart`.
- The notice pill and its severities: `client/packages/app/lib/src/widgets/status_pill.dart`; `StatusBanner` is the same pill in flow, with a timer per severity.
- The canvas: `canvas_notice.dart` and the hidden-ink chip in `canvas_zoom_indicator.dart`.
- The call stage still stacks its notices in flow as `StatusBanner`s above the tiles; moving them to rule 3's overlay is open work.
