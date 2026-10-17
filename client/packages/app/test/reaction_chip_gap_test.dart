// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gap *between* reaction chips, reported as looser than it should read:
/// "emoji reactions can be compacted left to right a bit more, less padding
/// between them."
///
/// Neither a chip's own internal padding nor the `Wrap`'s `spacing` value
/// was ever wrong on its own - both already sat at `AppSpacing.s4`, the
/// smallest step this scale has. The actual culprit is structural: every
/// chip is a `FocusableTapTarget`, which reserves `focusRingGap` +
/// `focusRingWidth` of invisible margin on *every* side for its own focus
/// ring, present whether or not the ring is ever drawn. That margin stacks
/// with the `Wrap`'s own spacing on both sides of every gap, so a single
/// `s4` step painted as three - one chip's margin, the spacing, the next
/// chip's margin. `message_row_parts.dart`'s `_reactionChipSpacing` cancels
/// the one truly redundant piece (the explicit spacing itself), leaving the
/// two chips' own irreducible ring margins as the entire remaining gap.
///
/// It deliberately stops there rather than cancelling a ring margin too:
/// each chip's invisible hit box is opaque to a tap regardless of what is
/// painted under it - `find.byType(AppChip)` reads exactly that box, since
/// `AppChip` returns `FocusableTapTarget` directly with no render object of
/// its own between them - so pulling the boxes into overlapping (a
/// negative spacing) would erase the dead zone that exists today between
/// two chips: every point in the visible gap would then always resolve to
/// reacting on one chip or the other, where today a tap there does
/// nothing. The second test below is what actually proves that dead zone
/// survives, not just that the pills look closer together.
///
/// This measures the true painted pill edges (the innermost `Container` in
/// each chip's subtree, past the invisible hit-target and ring wrappers)
/// with plain `tester.getRect` subtraction, not `support/geometry.dart`'s
/// `edgeGap`: that helper measures a widget's clearance from a *matching*
/// edge of a bounding container, which is the shape a safe-area inset
/// needs, not the shape a facing gap between two side-by-side siblings
/// needs - forcing it here would read backwards at the call site. A
/// fixture with only one reaction would never exercise a gap at all, so
/// this always seeds two.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/reactions_row.dart';
import 'package:slimm_design_system/design_system.dart';

const _firstEmoji = '\u{1F389}';
const _secondEmoji = '\u{2764}\u{FE0F}';

/// What is left once `_reactionChipSpacing` cancels the Wrap's own spacing
/// to zero: each of the two neighbouring chips' own irreducible ring
/// margin, still present on both sides of the gap.
const double _expectedPillGap = 2 * (focusRingGap + focusRingWidth);

Widget _harness({double? width}) {
  final row = ReactionsRow(
    reactions: const [
      api.ReactionSummary(emoji: _firstEmoji, count: 2, reacted: true),
      api.ReactionSummary(emoji: _secondEmoji, count: 1, reacted: false),
    ],
    onReactionTap: (_) {},
  );
  return MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: width == null ? row : SizedBox(width: width, child: row),
    ),
  );
}

/// The chip's own painted pill, past the invisible ring and hit-target
/// wrappers `FocusableTapTarget` builds around every chip's real content -
/// the last (innermost) `Container` in that chip's subtree.
Finder _pill(String emoji) => find
    .descendant(
      of: find.byKey(ValueKey('reaction-$emoji')),
      matching: find.byType(Container),
    )
    .last;

void main() {
  testWidgets(
    'adjacent reaction chips sit their own ring margins apart, not a third '
    'stacked spacing step on top',
    (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final firstRight = tester.getRect(_pill(_firstEmoji)).right;
      final secondLeft = tester.getRect(_pill(_secondEmoji)).left;

      expect(
        secondLeft - firstRight,
        closeTo(_expectedPillGap, 0.5),
        reason:
            'the visible gap between two reaction pills should be exactly '
            'the two chips\' own focus-ring margins, with the Wrap\'s own '
            'spacing cancelled out rather than stacked on top of them',
      );
    },
  );

  testWidgets(
    'the dead zone between two reaction chips survives the tightened gap',
    (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      // See the library doc above: this reads the opaque hit box, not the pill.
      final chips = find.byType(AppChip);
      final firstHitBox = tester.getRect(chips.at(0));
      final secondHitBox = tester.getRect(chips.at(1));

      expect(
        secondHitBox.left - firstHitBox.right,
        greaterThanOrEqualTo(0),
        reason:
            'two chips\' invisible hit boxes must never overlap, or a tap '
            'in the space between them would always land on one of them',
      );
    },
  );

  testWidgets('wrapped reaction rows keep the same tightened gap vertically', (
    tester,
  ) async {
    // Narrow enough the two chips cannot share a line, so runSpacing governs.
    await tester.pumpWidget(_harness(width: 60));
    await tester.pumpAndSettle();

    final firstBottom = tester.getRect(_pill(_firstEmoji)).bottom;
    final secondTop = tester.getRect(_pill(_secondEmoji)).top;

    expect(
      secondTop - firstBottom,
      closeTo(_expectedPillGap, 0.5),
      reason:
          'runSpacing carries the identical doubled-margin problem '
          'spacing does, and should be cancelled the same way',
    );
  });
}
