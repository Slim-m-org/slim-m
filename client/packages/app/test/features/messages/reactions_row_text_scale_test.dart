// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// At 200% text scale a reaction chip grows with its count and emoji instead of
/// drawing them past its border, and on a phone every chip's hit box meets the
/// 44dp touch floor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/reactions_row.dart';
import 'package:slimm_design_system/design_system.dart';

const _reactions = [
  api.ReactionSummary(emoji: '\u{1F44D}', count: 12, reacted: true),
  api.ReactionSummary(emoji: '\u{2764}', count: 148, reacted: false),
  api.ReactionSummary(emoji: '\u{1F389}', count: 7, reacted: false),
];

Future<void> _pump(WidgetTester tester, {required double scale}) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      builder: (context, child) => MediaQuery(
        data: MediaQueryData.fromView(
          View.of(context),
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 260,
            child: ReactionsRow(reactions: _reactions, onReactionTap: (_) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

Finder _border(Finder chip) => find
    .descendant(
      of: chip,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).border != null,
      ),
    )
    .last;

void main() {
  testWidgets('chip contents stay inside the border at 200% text', (
    tester,
  ) async {
    await _pump(tester, scale: 2);
    for (final r in _reactions) {
      final chip = find.byKey(ValueKey('reaction-${r.emoji}'));
      final box = tester.getRect(_border(chip));
      final count = tester.renderObject<RenderBox>(
        find.descendant(of: chip, matching: find.text('${r.count}')),
      );
      // A clamped paragraph reports the border's height, so ask for its natural one.
      final natural = count.getMinIntrinsicHeight(double.infinity);
      expect(box.height, greaterThanOrEqualTo(natural), reason: r.emoji);
    }
  });

  testWidgets('every chip is inside the bubble column at 200% text', (
    tester,
  ) async {
    await _pump(tester, scale: 2);
    for (final r in _reactions) {
      final box = tester.getRect(
        _border(find.byKey(ValueKey('reaction-${r.emoji}'))),
      );
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(260));
    }
  });

  testWidgets('a chip hit box is at least 44dp on a phone', (tester) async {
    await _pump(tester, scale: 1);
    for (final r in _reactions) {
      final hit = tester.getSize(find.byKey(ValueKey('reaction-${r.emoji}')));
      expect(hit.height, greaterThanOrEqualTo(44), reason: r.emoji);
    }
  });
}
