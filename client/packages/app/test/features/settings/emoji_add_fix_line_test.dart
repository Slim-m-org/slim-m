// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "N names need fixing" line keeps its button beside the text while they
/// fit and drops it under the text when large type leaves no room.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;

import 'emoji_add_harness.dart';

const _zorg = api.CustomEmoji(
  id: 'e-zorg',
  name: 'zorg',
  uploaderId: 'other',
  createdAt: 0,
);

Future<void> _stageOneTaken(
  WidgetTester tester, {
  required Size size,
  required double scale,
}) async {
  final h = EmojiHarness(
    existing: const [_zorg],
    picks: [emojiPick('zorg.png'), emojiPick('fine.png')],
  );
  await h.pump(tester, size: size, textScale: scale);
  await h.choose(tester);
}

void main() {
  testWidgets('the button sits beside the text at normal size', (tester) async {
    await _stageOneTaken(tester, size: const Size(1280, 1600), scale: 1);

    final text = tester.getRect(find.text('1 name needs fixing.'));
    final button = tester.getRect(find.text('Show first'));
    expect(button.left, greaterThan(text.right));
    expect((button.center.dy - text.center.dy).abs(), lessThan(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the button drops under the text at 3x on a phone', (
    tester,
  ) async {
    await _stageOneTaken(tester, size: const Size(390, 1800), scale: 3);

    expect(
      tester.takeException(),
      isNull,
      reason: 'the line does not overflow',
    );
    final text = tester.getRect(find.text('1 name needs fixing.'));
    final button = tester.getRect(find.text('Show first'));
    expect(button.top, greaterThanOrEqualTo(text.bottom));
  });
}
