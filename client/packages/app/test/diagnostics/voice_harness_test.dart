// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice quality harness entry point must stay out of every ordinary build.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/diagnostics/voice_harness.dart';

void main() {
  test('the harness is compiled out unless the define is passed', () {
    expect(kVoiceHarness, isFalse);
  });

  test('the channel comes from its flag and nowhere else', () {
    expect(harnessChannel(const ['--voice-harness-channel=abc']), 'abc');
    expect(
      harnessChannel(const ['--autostart', '--voice-harness-channel=x-1']),
      'x-1',
    );
    expect(harnessChannel(const ['--autostart']), isNull);
    expect(harnessChannel(const []), isNull);
  });
}
