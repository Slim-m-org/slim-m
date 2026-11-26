// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reactions row pulls up under the body by one spacing step (owner fix
/// #302, "a few pixels too low on a real phone") and its own box is that step
/// shorter, so the gap above the chips and the gap below them are both right.
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
  testWidgets('the row pulls up one step with no dead space below it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness([
        const api.ReactionSummary(emoji: '\u{1F44D}', count: 1, reacted: false),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final aboveBottom = tester.getBottomLeft(find.byKey(_above)).dy;
    final chips = tester.getRect(find.byWidgetPredicate((w) => w is Wrap));
    final row = tester.getRect(
      find.byWidgetPredicate((w) => w is ReactionsRow),
    );

    expect(chips.top - aboveBottom, -AppSpacing.s4, reason: 'pulled up a step');
    expect(row.top, aboveBottom, reason: 'the row box starts under the body');
    expect(row.bottom, chips.bottom, reason: 'no dead space under the chips');
    expect(row.height, chips.height - AppSpacing.s4);
  });

  testWidgets('a message with no reactions renders no reactions row', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(const []));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getSize(find.byWidgetPredicate((w) => w is ReactionsRow)),
      Size.zero,
      reason: 'an unreacted message must occupy no space for reactions',
    );
  });
}
