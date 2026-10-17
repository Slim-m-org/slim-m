// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gap above the reactions row, reported as sitting a few pixels too
/// low on a real phone.
///
/// `AppSpacing` has no negative step, so the fix pulls the row tight by the
/// smallest positive one (`s4`) applied as a top offset, rather than a
/// hardcoded pixel count. Measured against a plain spacer above it, not
/// against `MessageBody`'s own text: a font's line-height leftover would
/// make the raw gap depend on glyph metrics this test has no business
/// asserting on.
///
/// The offset is a `Transform.translate`, not a negative `Padding` (which
/// asserts non-negative insets and throws). A transform repositions its
/// child at paint time without moving its own render box, so the gap has to
/// be measured from the chips themselves - `Wrap`, the row's one child -
/// rather than from `ReactionsRow`'s own position, which stays exactly
/// where it would have been at a flush 0.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/reactions_row.dart';
import 'package:slimm_design_system/design_system.dart';

const _above = Key('above');

Widget _harness(List<api.ReactionSummary> reactions) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20, key: _above),
        ReactionsRow(reactions: reactions, onReactionTap: (_) {}),
      ],
    ),
  ),
);

void main() {
  testWidgets(
    'the reactions row overlaps the row above it by one spacing step',
    (tester) async {
      await tester.pumpWidget(
        _harness([
          const api.ReactionSummary(
            emoji: '\u{1F44D}',
            count: 1,
            reacted: false,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      final aboveBottom = tester.getBottomLeft(find.byKey(_above)).dy;
      // The chips, not ReactionsRow's own box: see the library doc above.
      final reactionsTop = tester.getTopLeft(find.byType(Wrap)).dy;

      expect(
        reactionsTop - aboveBottom,
        -AppSpacing.s4,
        reason:
            'the gap above the reactions row should be pulled tight by the '
            'existing s4 step, not left flush or offset by an invented value',
      );
    },
  );

  testWidgets('a message with no reactions renders no reactions row', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(const []));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(ReactionsRow)),
      Size.zero,
      reason: 'an unreacted message must occupy no space for reactions',
    );
  });
}
