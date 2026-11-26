// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reactions row sits flush under what is above it. It once pulled up by
/// one step with a paint-time transform, which left the same step of dead
/// space under the chips and made the gaps above and below them uneven.
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
  testWidgets('the reactions row sits flush under the row above it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness([
        const api.ReactionSummary(emoji: '\u{1F44D}', count: 1, reacted: false),
      ]),
    );
    await tester.pumpAndSettle();

    final aboveBottom = tester.getBottomLeft(find.byKey(_above)).dy;
    final reactionsTop = tester.getTopLeft(find.byType(Wrap)).dy;

    expect(
      reactionsTop - aboveBottom,
      0,
      reason: 'no pull over the body, so no phantom gap under the chips',
    );
  });

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
