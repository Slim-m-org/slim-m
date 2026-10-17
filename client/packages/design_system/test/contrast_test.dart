// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// WCAG 2.1 relative-luminance contrast, computed from the real design tokens so
/// this file is the token contrast gate rather than a description of one.
///
/// Two things the 2026-07-26 identity review changed here:
///
/// - True black was never tested. The theme map held light and dark only, so the
///   one theme whose contrast is hardest, everything collapsing toward #000000,
///   was the one nothing checked.
/// - Code block colours are gated now. Five roles across three themes is fifteen
///   values, and a fenced block is exactly the surface that quietly ends up the
///   single inaccessible thing in an otherwise AA product.
///
/// Each section below is the full reasoning for one test in [main]; the test
/// bodies carry a two-line pointer back here.
///
/// ## Accent fill
///
/// The pair a split accent exists to make checkable: the fill is brand-true
/// rather than contrast-bound, so what matters is the text on top of it, not the
/// fill against the page behind it.
///
/// ## Danger and warning text
///
/// These carry the messages a user most needs to read and is least able to guess
/// from context: a destructive confirmation, an invite about to lapse. A palette
/// change that quietly dropped one below AA would be least noticeable exactly
/// where it matters most.
///
/// ## Status colours
///
/// Deliberately NOT an AA assertion. A status colour is only ever a small filled
/// shape, never text, and every presence indicator pairs its hue with a distinct
/// shape so the state survives greyscale. Holding these to a text ratio would
/// force four muddy colours that no longer read as traffic lights, and would buy
/// nothing, because nobody reads them.
///
/// What is asserted is only that each dot is visible against the surfaces it is
/// drawn on, and that no two states share a value outright.
///
/// Deliberately NOT asserted: a contrast ratio between two status hues. Contrast
/// ratio measures luminance alone, and the away amber and the dnd red sit at
/// almost exactly the same luminance (1.04:1 between them) while being obviously
/// different colours to anyone with normal colour vision. A first draft of this
/// test gated that pair and "failed" a palette that is fine. Telling the states
/// apart is the shape's job, which is asserted in the AppStatusDot component
/// tests, not here.
///
/// ## Disabled text
///
/// The real invariant, and the only one worth gating: disabled must read as
/// unavailable rather than as merely de-emphasised, so it has to sit below
/// textSecondary. If the two converge, a user cannot tell a control they may not
/// use from one that is simply quiet.
///
/// Its absolute ratio is reported rather than gated, the same way the border is.
/// WCAG 1.4.3 explicitly exempts inactive controls, so any floor here would be a
/// house rule invented in this file, and light mode currently lands at 2.96:1 -
/// close enough to a round number that gating it would be picking a threshold to
/// match the palette rather than the other way round.
///
/// ## Borders
///
/// The hairline separator stays reported rather than asserted. The edge of an
/// input or a card is gated at 3:1 in `component_boundary_contrast_test.dart`,
/// against `borderStrong`; see decision 0004's 2026-10-01 addendum.
///
/// WCAG 1.4.11 asks 3:1 of a UI component boundary. Reaching that on #000000
/// needs roughly #5A5A5A, which is not a hairline any more, it is a visible grey
/// rule, and it would undo the border-first look the token exists to serve. The
/// identity review raised true black from #23282D to #2C3238, a real improvement
/// (1.41:1 to 1.62:1) and still nowhere near 3:1.
///
/// So the open question is not the value, it is whether a separator hairline
/// counts as a UI component under 1.4.11 or as an incidental boundary that is
/// exempt. Until that is settled these print, so a regression shows up in CI
/// output and the numbers cannot silently drift.
///
/// ## Canvas cursor hues
///
/// Categorical identity for remote participants. They only work as identity if
/// no two read as the same colour, which is the property worth pinning rather
/// than any particular hex.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

double _channel(int v) {
  final c = v / 255.0;
  if (c <= 0.03928) return c / 12.92;
  return math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color color) {
  final argb = color.toARGB32();
  final r = _channel((argb >> 16) & 0xFF);
  final g = _channel((argb >> 8) & 0xFF);
  final b = _channel(argb & 0xFF);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void _expectAA(Color fg, Color bg, String what) {
  expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: what);
}

void main() {
  final themes = {
    'light': AppTokens.light,
    'dark': AppTokens.dark,
    'trueBlack': AppTokens.trueBlack,
  };

  themes.forEach((name, t) {
    test('$name body text and accent meet WCAG AA', () {
      for (final surface in [t.surfaceSunken, t.surfaceBase, t.surfaceRaised]) {
        _expectAA(t.textPrimary, surface, '$name primary text');
        _expectAA(t.textSecondary, surface, '$name secondary text');
        _expectAA(t.accent, surface, '$name accent as text');
      }
    });

    test('$name accent fill is legible with what sits on it', () {
      // What matters is the text on the fill, not the fill against the page
      // behind it. See "Accent fill" in the library doc above.
      _expectAA(t.accentOn, t.accentFill, '$name accentOn over accentFill');
      // Accent as text over accentSoft (mention pill, operator chip): the one accent pair no test covered, at 4.45:1 in light until accentSoft was lifted.
      _expectAA(t.accent, t.accentSoft, '$name accent text over accentSoft');
    });

    test('$name code block colours meet WCAG AA', () {
      for (final role in t.code.all) {
        _expectAA(role, t.surfaceRaised, '$name code role on raised surface');
      }
    });

    test('$name danger and warning text meet WCAG AA', () {
      // The messages a user most needs to read and can least guess from
      // context. See "Danger and warning text" in the library doc above.
      for (final surface in [t.surfaceSunken, t.surfaceBase, t.surfaceRaised]) {
        _expectAA(t.dangerText, surface, '$name danger text');
        _expectAA(t.warnText, surface, '$name warning text');
      }
    });

    test('$name status colours are not relied on to be legible as text', () {
      // Deliberately NOT an AA assertion, and deliberately no ratio between two
      // status hues. See "Status colours" in the library doc above.
      for (final surface in [t.surfaceSunken, t.surfaceRaised]) {
        for (final status in t.status.all) {
          expect(
            _contrast(status, surface),
            greaterThanOrEqualTo(1.6),
            reason: '$name status dot must at least be visible on $surface',
          );
        }
      }
      expect(
        t.status.all.toSet(),
        hasLength(t.status.all.length),
        reason: '$name has two presence states sharing one colour',
      );
    });

    test('$name disabled text is quieter than secondary', () {
      // The only invariant worth gating: disabled must sit below textSecondary
      // or it reads as quiet rather than unavailable. See the library doc.
      expect(
        _contrast(t.textDisabled, t.surfaceBase),
        lessThan(_contrast(t.textSecondary, t.surfaceBase)),
        reason: '$name disabled must be quieter than secondary',
      );

      // Reported rather than gated, the same way the border below is: WCAG
      // 1.4.3 exempts inactive controls. See "Disabled text" in the library doc.
      final ratio = _contrast(t.textDisabled, t.surfaceBase);
      // ignore: avoid_print
      print('$name disabled text on base: '
          '${ratio.toStringAsFixed(2)}:1 (not gated, WCAG exempts it)');
    });

    // Not asserted on purpose: whether a hairline is a UI component under WCAG
    // 1.4.11 is unsettled. See "Borders" in the library doc above.
    test('$name border contrast is reported, not gated', () {
      for (final entry in {
        'sunken': t.surfaceSunken,
        'base': t.surfaceBase,
        'raised': t.surfaceRaised,
      }.entries) {
        final value = _contrast(t.borderSubtle, entry.value).toStringAsFixed(2);
        // ignore: avoid_print
        print('$name border on ${entry.key}: $value:1 (target 3.0, unsettled)');
      }
    });
  });

  themes.forEach((name, t) {
    test('$name applyHighContrast strengthens the border and disabled text',
        () {
      // See high_contrast.dart's own doc for why only these two roles move.
      final boosted = applyHighContrast(t);
      expect(
        _contrast(boosted.borderSubtle, t.surfaceBase),
        greaterThan(_contrast(t.borderSubtle, t.surfaceBase)),
        reason: '$name boosted border must read stronger than the hairline',
      );
      expect(
        _contrast(boosted.textDisabled, t.surfaceBase),
        greaterThan(_contrast(t.textDisabled, t.surfaceBase)),
        reason: '$name boosted disabled text must read stronger',
      );
      // Untouched: colour-blind safety must not depend on this toggle.
      expect(boosted.accent, t.accent);
      expect(boosted.status, t.status);
      expect(boosted.dangerText, t.dangerText);
      expect(boosted.warnText, t.warnText);
    });
  });

  test('canvas cursor hues are a closed set of six distinct values', () {
    // Categorical identity for remote participants: no two may read as the same
    // colour, which is the property worth pinning rather than any hex.
    const cursors = AppCanvasColors.cursors;
    expect(cursors, hasLength(6));
    expect(cursors.toSet(), hasLength(6), reason: 'no duplicate cursor hues');
  });

  test('embed accent swatches are a closed set of six distinct values', () {
    // Never text, so distinctness is what matters, not a WCAG ratio.
    final swatches = [
      AppEmbedAccents.red,
      AppEmbedAccents.orange,
      AppEmbedAccents.yellow,
      AppEmbedAccents.green,
      AppEmbedAccents.blue,
      AppEmbedAccents.purple,
    ];
    expect(swatches.toSet(), hasLength(6), reason: 'no duplicate accent hues');
  });
}
