// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong's decisions reach the debug log, so "I can hear keys" can be read
/// from a copied log instead of guessed at.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  CaptureNoiseSuppression capture(List<String> lines) =>
      CaptureNoiseSuppression(
        supported: true,
        restart: ({required webrtcNoiseSuppression}) async {},
        canRestart: () => true,
        onNativeStrongChanged: () {},
        log: lines.add,
      );

  void readings(CaptureNoiseSuppression c, int count, {required bool active}) {
    for (var i = 0; i < count; i++) {
      c.onReading(strongActive: active, micOpen: true);
    }
  }

  test('a mic rnnoise cannot run on is logged once, with the reason', () {
    fakeAsync((async) {
      final lines = <String>[];
      final c = capture(lines)..setStrong(true);
      readings(c, kStrongInactivePolls * 2, active: false);
      async.elapse(kCaptureRestartDebounce * 2);

      expect(lines.first, 'voice: Strong noise suppression on');
      expect(lines.where((l) => l.contains('not running')), hasLength(1));
      expect(lines.last, contains('48 kHz'));
    });
  });

  test('a running Strong is logged once per switch-on', () {
    fakeAsync((async) {
      final lines = <String>[];
      final c = capture(lines)..setStrong(true);
      readings(c, kStrongActivePolls * 3, active: true);
      c.setStrong(false);
      c.setStrong(true);
      readings(c, kStrongActivePolls, active: true);

      expect(
          lines.where((l) => l.endsWith('running on this mic')), hasLength(2));
      expect(lines, contains('voice: Strong noise suppression off'));
    });
  });
}
