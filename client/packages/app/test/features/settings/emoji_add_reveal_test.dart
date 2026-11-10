// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Show first" reaches the flagged row however far down a long list it sits
/// and however large the text is, because it measures the rows it has built
/// rather than assuming every row is one height.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;

import '../../support/geometry.dart';
import 'emoji_add_harness.dart';

const _zorg = api.CustomEmoji(
  id: 'e-zorg',
  name: 'zorg',
  uploaderId: 'other',
  createdAt: 0,
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder get _flagged => find.byKey(const ValueKey('emoji-name-zorg.png'));

Future<void> _showFirst(
  WidgetTester tester, {
  required Size size,
  required int count,
  required int flaggedAt,
  required double scale,
}) async {
  final h = EmojiHarness(
    existing: const [_zorg],
    picks: [
      for (var i = 0; i < count; i++)
        emojiPick(i == flaggedAt ? 'zorg.png' : 'pic$i.png'),
    ],
    onBulk: (r) => emojiJson(const {}),
  );
  await h.pump(tester, size: size, textScale: scale);
  await h.choose(tester);
  expect(_flagged, findsNothing, reason: 'built lazily, far off screen');

  for (var tap = 0; tap < 2; tap++) {
    await tester.tap(find.text('Show first'));
    await _frames(tester);

    expect(_flagged, findsOneWidget, reason: 'tap ${tap + 1} reached the row');
    final list = find.byKey(const ValueKey('emoji-review-list'));
    for (final part in [_flagged, find.text('Already taken.')]) {
      expectClearOfEdge(tester, part, GeometryEdge.top, from: list);
      expectClearOfEdge(tester, part, GeometryEdge.bottom, from: list);
    }
  }
}

void main() {
  for (final flaggedAt in const [150, 199]) {
    testWidgets('Show first reaches row $flaggedAt of 200 on a desktop', (
      tester,
    ) async {
      await _showFirst(
        tester,
        size: const Size(1280, 1600),
        count: 200,
        flaggedAt: flaggedAt,
        scale: 1,
      );
    });
  }

  testWidgets('Show first reaches row 75 of 90 at twice the text on a phone', (
    tester,
  ) async {
    await _showFirst(
      tester,
      size: const Size(390, 1800),
      count: 90,
      flaggedAt: 75,
      scale: 2,
    );
  });

  testWidgets(
    'Show first reaches row 75 of 90 at twice the text on a desktop',
    (tester) async {
      await _showFirst(
        tester,
        size: const Size(1280, 1600),
        count: 90,
        flaggedAt: 75,
        scale: 2,
      );
    },
  );
}
