// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of `msg-swipe-to-reply`, phone only (swipe is a touch
/// layout, so a desktop window never offers it): a row held part way through
/// its drag, and the composer after the reply committed. PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1; otherwise each case asserts a clean
/// layout.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;

import '../ui_snapshot_support.dart';
import 'ui_review_messages_support.dart';

const _surface = 'msg-swipe-to-reply';
const _ada = 'user-ada';
const _nick = 'user-nick';

const _target = 'sounds good, I will take the resync review this afternoon';

List<api.Message> _thread() => [
  reviewMessage(1, _nick, 'can someone take the resync review?'),
  reviewMessage(2, _ada, _target),
  reviewMessage(3, _nick, 'thanks, ping me when it is ready'),
];

Offset _emptySpace(ReviewScene scene) {
  final name = scene.tester.getCenter(find.text('Ada Lovelace'));
  return Offset(280, name.dy);
}

Future<void> _dragBy(
  ReviewScene scene,
  TestGesture gesture,
  double distance,
) async {
  const steps = 8;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(distance / steps, 0));
    await scene.tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('mid-drag at phone', (tester) async {
    late TestGesture held;
    await captureMessages(
      tester,
      surface: _surface,
      state: 'mid-drag',
      viewport: 'phone',
      messages: _thread(),
      act: (scene) async {
        held = await scene.tester.startGesture(_emptySpace(scene));
        await _dragBy(scene, held, 80);
      },
    );
    await held.up();
  });

  testWidgets('committed at phone', (tester) async {
    await captureMessages(
      tester,
      surface: _surface,
      state: 'committed',
      viewport: 'phone',
      messages: _thread(),
      act: (scene) async {
        final finger = await scene.tester.startGesture(_emptySpace(scene));
        await _dragBy(scene, finger, 100);
        await finger.up();
        await scene.frames(2);
      },
    );
  });
}
