// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong's decisions reach the debug log, so "I can hear keys" can be read
/// from a copied log instead of guessed at.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

void main() {
  StrongNoiseSuppression strong(List<String> lines) => StrongNoiseSuppression(
        supported: true,
        onChanged: () {},
        log: (m, {level = LogLevel.info}) => lines.add(m),
      );

  void readings(StrongNoiseSuppression s, int count, {required bool active}) {
    for (var i = 0; i < count; i++) {
      s.onReading(strongActive: active, micOpen: true);
    }
  }

  test('a mic rnnoise cannot run on is logged once, with libwebrtc still on',
      () {
    final lines = <String>[];
    final s = strong(lines)..setStrong(true);
    readings(s, kStrongInactivePolls * 2, active: false);

    expect(lines.first, startsWith('voice-ns: choice strong=on'));
    final inactive = lines.where((l) => l.contains('strong inactive'));
    expect(inactive, hasLength(1));
    expect(inactive.single, contains('webrtc_ns=on'));
    expect(lines.any((l) => l.contains('restart')), isFalse);
  });

  test('a running Strong is logged once per switch-on', () {
    final lines = <String>[];
    final s = strong(lines)..setStrong(true);
    readings(s, kStrongActivePolls * 3, active: true);
    s.setStrong(false);
    s.setStrong(true);
    readings(s, kStrongActivePolls, active: true);

    expect(lines.where((l) => l.contains('voice-ns: strong active (')),
        hasLength(2));
    expect(
        lines.any((l) => l.startsWith('voice-ns: choice strong=off')), isTrue);
  });

  test('a stray inactive frame logs nothing, a verdict logs both edges', () {
    final lines = <String>[];
    final s = strong(lines)..setStrong(true);
    readings(s, kStrongActivePolls, active: true);
    readings(s, 3, active: false);
    readings(s, kStrongActivePolls, active: true);
    expect(lines.where((l) => l.contains('inactive')), isEmpty);
    readings(s, kStrongInactivePolls, active: false);
    readings(s, kStrongActivePolls, active: true);
    expect(lines.where((l) => l.contains('strong inactive')), hasLength(1));
    expect(lines.where((l) => l.contains('strong active again')), hasLength(1));
  });
}
