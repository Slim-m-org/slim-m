// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong's decisions reach the debug log, so "I can hear keys" can be read
/// from a copied log instead of guessed at.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

void main() {
  CaptureNoiseSuppression capture(List<String> lines) =>
      CaptureNoiseSuppression(
        supported: true,
        restart: ({required webrtcNoiseSuppression}) async {},
        canRestart: () => true,
        onNativeStrongChanged: () {},
        log: (m, {level = LogLevel.info}) => lines.add(m),
      );

  void readings(CaptureNoiseSuppression c, int count, {required bool active}) {
    for (var i = 0; i < count; i++) {
      c.onReading(strongActive: active, micOpen: true);
    }
  }

  test('a mic rnnoise cannot run on is logged once, with the reason', () {
    fakeAsync((async) {
      final lines = <String>[];
      final c = capture(lines)
        ..opened(webrtcNoiseSuppression: false)
        ..setStrong(true);
      readings(c, kStrongInactivePolls * 2, active: false);
      async.elapse(kCaptureRestartDebounce * 2);

      expect(lines.first, startsWith('voice-ns: choice strong=on'));
      expect(
          lines.where((l) => l.contains('fallback to standard')), hasLength(1));
      expect(lines.where((l) => l.contains('strong inactive')), hasLength(1));
      expect(
          lines.where((l) => l.contains('restarting mic: webrtc_ns off to on')),
          hasLength(1));
      expect(lines.last, contains('webrtc_ns=on'));
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

      expect(lines.where((l) => l.contains('voice-ns: strong active (')),
          hasLength(2));
      expect(lines.any((l) => l.startsWith('voice-ns: choice strong=off')),
          isTrue);
    });
  });

  test('a stray inactive frame logs nothing, a verdict logs both edges', () {
    fakeAsync((async) {
      final lines = <String>[];
      final c = capture(lines)..setStrong(true);
      readings(c, kStrongActivePolls, active: true);
      readings(c, 3, active: false);
      readings(c, kStrongActivePolls, active: true);
      expect(lines.where((l) => l.contains('inactive')), isEmpty);
      readings(c, kStrongInactivePolls, active: false);
      readings(c, kStrongActivePolls, active: true);
      expect(lines.where((l) => l.contains('strong inactive')), hasLength(1));
      expect(
          lines.where((l) => l.contains('strong active again')), hasLength(1));
    });
  });

  test('a restart held back by a mute is logged once, then runs', () {
    fakeAsync((async) {
      final lines = <String>[];
      var safe = false;
      final c = CaptureNoiseSuppression(
        supported: true,
        restart: ({required webrtcNoiseSuppression}) async {},
        canRestart: () => safe,
        onNativeStrongChanged: () {},
        log: (m, {level = LogLevel.info}) => lines.add(m),
      )..setStrong(true);
      c.retry();
      c.retry();
      expect(lines.where((l) => l.contains('restart deferred')), hasLength(1));
      safe = true;
      c.retry();
      async.elapse(kCaptureRestartDebounce * 2);
      expect(lines.where((l) => l.contains('mic restarted')), hasLength(1));
    });
  });
}
